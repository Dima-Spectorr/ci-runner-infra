#!/usr/bin/env bash
# =============================================================================
# check-pipefail-readers.sh — an early-exiting reader at the end of a pipeline
#                             is a 141, not a value
#
# USAGE
#   bash scripts/ci/check-pipefail-readers.sh [--selftest] [--root=<dir>]
#
# PURPOSE
#   Under `set -e` AND `pipefail`, a pipeline whose LAST stage stops reading
#   early — `head`, `grep -q`, `grep -m`, `sed q` — takes its writer down with
#   SIGPIPE. The writer exits 141, `pipefail` makes 141 the pipeline's status,
#   and `set -e` kills the shell. The rules name the two shapes that reach:
#
#     PFR1  a bare assignment `x="$(cmd | head -1)"` — the status of a simple
#           assignment IS the status of its command substitution
#     PFR2  a bare pipeline statement `cmd | head -5`
#     PFR3  a pipeline whose status IS the verdict — an `if`/`while` condition,
#           or one followed by `||`/`&&` — whose writer is IN-PROCESS (a
#           `printf`/`echo` of a shell variable, or a shell function). `set -e`
#           is suspended in a condition, so this never crashes: it silently
#           INVERTS the answer, which in a self-test is a green check over an
#           assertion that was never made
#     PFR0  the gate could not read a document, had no reader to read with, or
#           found nothing to check — reported, never passed
#
# WHY (measured, 2026-08-20)
#   docs/ci-optimization-catalog.md §5.2a has described this since the fleet's
#   first audit, and it carved out an exception that is wrong:
#
#     "When the value is what you want and the status is ignored
#      (x=$(cmd | head -1)), it is harmless"
#
#   The status is not ignored. `x=$(...)` is a simple command whose exit status
#   is the substitution's, so `set -e` acts on it. Demonstrable in one line:
#
#     $ bash -c 'set -euo pipefail; x="$(yes | head -1)"; echo reached'
#     $ echo $?
#     141
#
#   The carve-out is what consumers copied. IntegrateIT's `pr-check` installs
#   terraform and then asserts the version it got:
#
#     got="$("$bindir/terraform" version | head -1)"
#
#   Four of the last thirty failed `pr-check` runs died there with exit 141,
#   having downloaded and verified the correct binary. It is a race with how
#   much the writer had already buffered, so it passes on small output and fails
#   under load — and twice it failed inside a merge-queue speculative check,
#   which dequeues the pull request and re-runs the whole batch.
#
# WHAT IS NOT FLAGGED, AND WHY EACH EXEMPTION IS NARROW
#   * `local x=$(cmd | head -1)` / `export` / `declare`. The status of those is
#     the BUILTIN's, not the substitution's, so `set -e` never sees the 141.
#     Masking a failure is its own defect, but it is not this one, and flagging
#     it here would make the rule mean two things.
#   * A pipeline ending `|| true` or `|| :`. The author already said the status
#     is not the verdict.
#   * A file or block without BOTH `-e` and `pipefail` in effect. Most gates in
#     this repository run `set -uo pipefail` deliberately, precisely so an
#     assignment that returns 141 does not take the gate down.
#   * `if cmd | grep -q x; then` where the writer is a FILE READ or an external
#     command — `grep -qE "$re" "$file"`, `find . -type f | grep -q x`. There is
#     no in-process writer to kill, so there is nothing to invert. That is by
#     far the most common form in this repository, and leaving it alone is what
#     keeps PFR3 off the "gate somebody deletes" bar set in #216.
#
# WHY PFR3 DOES NOT REQUIRE `-e` (measured, 2026-08-22)
#   `set -e` is suspended in a condition, so the 141 never crashes anything —
#   which is why this shape is worse than PFR1/PFR2 rather than milder: the
#   status is consumed AS THE ANSWER. `grep -q` exits on its first match and
#   closes the pipe; the in-process writer (`printf`, or a function's own
#   `grep -v`) dies of EPIPE; `pipefail` makes 141 the pipeline's status; and a
#   predicate that FOUND its text returns false.
#
#   It fires only when the match lands early enough that the writer still holds
#   unwritten bytes, so it turns on input size and on the pipe buffer — 64 KiB
#   on Linux, 8 KiB on Windows. A label or a version string is safe in practice;
#   a whole file's contents is not. `build-cache-snapshot.selftest.sh` asked 44
#   of its questions this way and five failed in CI on a commit that had passed
#   on a laptop. Two were mutation cases, where a predicate stuck at false reads
#   as "mutation not caught" — the self-test accusing the code of a defect that
#   is not there.
#
#   THE FIX IS `grep -c … >/dev/null`: it reads to end of input, so nothing
#   upstream is ever cut off, and it still exits 1 when there is no match. For a
#   line number, `grep -n -m1 pat file` (a file argument has no writer to kill)
#   or `… | cut -d: -f1 | sed -n 1p` (`sed -n 1p` keeps reading).
#
# HOW A `run:` BLOCK'S OPTIONS ARE DECIDED
#   GitHub's `shell: bash` is `bash --noprofile --norc -eo pipefail {0}` — both
#   options, without the block saying so. The default shell (no `shell:` key) is
#   `bash -e {0}`: errexit, no pipefail. So a block can be in scope for this
#   rule without containing the word `pipefail` anywhere, which is exactly the
#   case a reader grepping for `set -euo pipefail` would miss.
#
# EXIT CODES
#   0 — clean
#   1 — a finding, or nothing found to check
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$REPO_ROOT"
SELFTEST=0

for arg in "$@"; do
  case "$arg" in
    --selftest) SELFTEST=1 ;;
    --root=*)   ROOT="${arg#--root=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

scan() {
  # Named, not inherited from `command not found` — see check-packer-inline-shell.sh.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "::error::[PFR0] python3 is not on PATH — the gate has no reader, so it checked nothing"
    return 1
  fi

  python3 - "$1" <<'PY'
import pathlib
import re
import sys

try:
    import yaml
except ImportError:
    print("::error::[PFR0] PyYAML is not importable — the gate cannot read a workflow")
    sys.exit(1)

root = pathlib.Path(sys.argv[1])

# --------------------------------------------------------------------------
# Is the last stage of this pipeline a reader that stops early?
# --------------------------------------------------------------------------

def split_pipeline(text):
    """Split on `|`, but not on `||`, and not inside quotes.

    Deliberately naive about everything else. A construct this does not
    understand yields a last segment that does not look like a reader, so the
    gate stays quiet — the failure direction a gate must have.
    """
    parts, buf, i, quote = [], [], 0, None
    while i < len(text):
        c = text[i]
        if quote:
            buf.append(c)
            if c == quote and (i == 0 or text[i - 1] != "\\"):
                quote = None
        elif c in "'\"":
            quote = c
            buf.append(c)
        elif c == "|":
            if i + 1 < len(text) and text[i + 1] == "|":
                buf.append("||")
                i += 2
                continue
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(c)
        i += 1
    parts.append("".join(buf))
    return parts


def reader_name(segment):
    """The command that stops reading early, or None."""
    seg = segment.strip()
    if not seg:
        return None
    # `cmd | head -1 || <anything>` — the pipeline's status is consumed by the
    # OR list, so `set -e` never sees it. That covers `|| true`, `|| :`, and the
    # `|| { echo ...; exit 1; }` block this repository's self-tests are written
    # with. `&&` is NOT a guard: an AND list still carries a failing status out.
    if re.search(r"(^|\s)\|\|(\s|$)", seg):
        return None
    words = seg.split()
    cmd = words[0]
    args = words[1:]
    if cmd == "head":
        return "head"
    if cmd in ("grep", "egrep", "fgrep"):
        for a in args:
            if a == "--quiet" or a.startswith("--max-count"):
                return cmd + " " + a
            if re.fullmatch(r"-[A-Za-z]*[qm][A-Za-z]*[0-9]*", a):
                return cmd + " " + a
        return None
    if cmd == "sed":
        # `sed 2q`, `sed -n '/x/{p;q}'`, `sed q`. A bare `q` inside the script.
        for a in args:
            body = a.strip("'\"")
            if re.fullmatch(r"[0-9]*q", body) or re.search(r"[;{]\s*q\s*[;}]?$", body):
                return "sed q"
        return None
    return None


FUNCDEF = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*\(\)\s*", re.M)
VERDICT_HEAD = re.compile(r"^\s*(?:if|elif|while|until)\s+")
ENVPREFIX = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
OPENER = re.compile(
    r"^(?:(?:function\s+)?[A-Za-z_][A-Za-z0-9_.-]*\s*\(\)\s*)?\{\s*|^(?:then|do|else)\s+"
)


def shell_functions(script):
    """Every function this script defines — the in-process writers of PFR3."""
    return set(FUNCDEF.findall(script))


def verdict_pipelines(text):
    """Every pipeline on this line whose status is READ, in order.

    The verdict is the whole point of PFR3, so it is decided structurally rather
    than by keyword: a pipeline in an `if`/`elif`/`while`/`until` condition, or
    one whose status is consumed by a following `||`/`&&`. Quotes and `$( )` are
    tracked so an operator inside either is not read as the top-level one.

    INSIDE A CONDITION, every element of an `&&`/`||` list is read, not just the
    first: `if [ -n "$out" ] && printf '%s' "$out" | grep -q FAIL; then` is the
    same inversion one segment further along, and looking only at the head of
    the list is how it hides. Outside a condition the head is all that is
    claimed, which is what keeps PFR3 disjoint from PFR1/PFR2.
    """
    s = text.strip()
    # `f() { printf ... | grep -q x || return 1; }` on one line is a whole
    # function, and the pipeline inside it is the same pipeline. Strip the
    # opener, or parts[0] is `f()` and the writer is never recognised.
    s = OPENER.sub("", s, count=1)
    verdict = bool(VERDICT_HEAD.match(s))
    if verdict:
        s = VERDICT_HEAD.sub("", s, count=1)
    while s.startswith("!"):
        s = s[1:].lstrip()
    segments, start = [], 0
    quote, depth, i = None, 0, 0
    while i < len(s):
        c = s[i]
        if quote:
            if c == quote and s[i - 1] != "\\":
                quote = None
            i += 1
            continue
        if c in "'\"":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0:
            if s.startswith("||", i) or s.startswith("&&", i):
                # An OR/AND list consumes the status, which is what makes it the
                # answer. This is the one place PFR3 and the PFR1/PFR2 `||`
                # exemption disagree, and deliberately so: there, `||` means the
                # author waived the status; here, it means the author READ it.
                segments.append(s[start:i].strip())
                if not verdict:
                    return segments
                start = i + 2
                i += 2
                continue
            if c == ";":
                segments.append(s[start:i].strip())
                return segments if verdict or len(segments) > 1 else []
        i += 1
    segments.append(s[start:].strip())
    return segments if verdict or len(segments) > 1 else []


def in_process_writer(segment, funcs):
    """True when killing this stage's writer kills a process INSIDE this shell.

    `printf`/`echo` of a shell variable, or a function defined in this script. A
    file argument (`grep -q pat file`) or an external command (`find`, `git`) is
    not: SIGPIPE there does not invert an answer computed in this shell, and
    flagging those is what would make the rule unusable.
    """
    words = segment.strip().split()
    i = 0
    while i < len(words) and ENVPREFIX.match(words[i]):
        i += 1
    if i >= len(words):
        return False
    cmd = words[i]
    if cmd in ("printf", "echo") and "$" in segment:
        return True
    return cmd in funcs


def verdict_reader(text, funcs):
    """The early-exiting reader of a PFR3 pipeline on this line, or None."""
    for pipeline in verdict_pipelines(text):
        if "|" not in pipeline:
            continue
        parts = split_pipeline(pipeline)
        if len(parts) < 2:
            continue
        name = reader_name(parts[-1])
        if not name:
            continue
        if in_process_writer(parts[0], funcs):
            return name
    return None


HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(\"?)\$\((.*)\)\2\s*$")
DECLARER = re.compile(r"^\s*(local|export|declare|typeset|readonly)\s")
STARTER = re.compile(r"^\s*(if|elif|while|until|then|else|do|!|&&|\|\|)\b")


def blank_heredocs(script):
    """Replace every heredoc BODY with an empty line, keeping the numbering.

    A heredoc is data, not code. This gate's own self-test writes the offending
    idiom into `cat >file <<'SH'` fixtures, and so does every script that embeds
    an example — reading those as the enclosing script's own statements is how a
    correctness gate ends up reporting on its own test data.
    """
    out = []
    pending = []  # (terminator, dashed)
    for line in script.split("\n"):
        if pending:
            term, dashed = pending[0]
            probe = line.lstrip("\t") if dashed else line
            out.append("")
            if probe.rstrip() == term:
                pending.pop(0)
            continue
        out.append(line)
        stripped = line.split("#", 1)[0]
        for m in HEREDOC.finditer(stripped):
            pending.append((m.group(2), "<<-" in m.group(0)))
    return "\n".join(out)


def logical_lines(script):
    """(line number of the first physical line, joined text) per logical line."""
    out = []
    lines = script.split("\n")
    i = 0
    while i < len(lines):
        start = i
        buf = lines[i].rstrip()
        while buf.endswith("\\") or buf.rstrip().endswith("|"):
            if buf.endswith("\\"):
                buf = buf[:-1]
            i += 1
            if i >= len(lines):
                break
            buf = buf.rstrip() + " " + lines[i].strip()
        out.append((start + 1, buf))
        i += 1
    return out


def crash_finding(text):
    """(rule, reader) for the shapes whose 141 reaches `set -e`, or None."""
    if DECLARER.match(text):
        return None
    m = ASSIGN.match(text)
    if m:
        inner = m.group(3)
        name = reader_name(split_pipeline(inner)[-1]) if "|" in inner else None
        return ("PFR1", name) if name else None
    if STARTER.match(text) or "|" not in text:
        return None
    # An assignment this far in is `x=1 cmd | head` (an env prefix) or a
    # form ASSIGN did not recognise; treat it as a bare pipeline.
    name = reader_name(split_pipeline(text)[-1])
    return ("PFR2", name) if name else None


def findings(script, errexit, pipefail):
    """(line offset, rule, reader, text) for every offending logical line."""
    if not pipefail:
        return []
    funcs = shell_functions(script)
    hits = []
    for lineno, raw in logical_lines(blank_heredocs(script)):
        text = raw.strip()
        if not text or text.startswith("#"):
            continue

        # PFR1/PFR2 are about a 141 that CRASHES the shell, so they need -e too.
        # PFR3 is about one that is READ as an answer, and needs only pipefail.
        # The two sets are disjoint by construction: PFR3 requires the status to
        # be consumed (a condition, or an OR/AND list), and PFR1/PFR2 both stop
        # at exactly that.
        if errexit:
            hit = crash_finding(text)
            if hit:
                hits.append((lineno, hit[0], hit[1], text))
                continue

        name = verdict_reader(text, funcs)
        if name:
            hits.append((lineno, "PFR3", name, text))
    return hits


def opts_from_script(script):
    errexit = bool(re.search(r"^\s*set\s+-[A-Za-z]*e", script, re.M)) or bool(
        re.search(r"^\s*set\s+-o\s+errexit", script, re.M)
    )
    pipefail = bool(re.search(r"\bpipefail\b", script))
    return errexit, pipefail


# --------------------------------------------------------------------------
# Units to scan
# --------------------------------------------------------------------------

units = []  # (path, offset, script, errexit, pipefail, raw-file-text-or-None)
errors = []

for path in sorted(root.rglob("*.sh")):
    if ".git" in path.parts:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        errors.append("%s: %s" % (path, exc))
        continue
    e, p = opts_from_script(text)
    # raw=None: this IS the file, so a finding's line number is already absolute.
    units.append((path, 0, text, e, p, None))


def shell_opts(shell):
    """errexit/pipefail implied by a step's `shell:`, or None if not shell."""
    if shell is None:
        # GitHub's default on Linux is `bash -e {0}`: errexit, no pipefail.
        return True, False
    s = shell.strip()
    if s == "bash":
        # `bash --noprofile --norc -eo pipefail {0}` — both, unstated.
        return True, True
    if s == "sh":
        return True, False
    if s.startswith("bash ") or s.startswith("sh "):
        return ("-e" in s or "errexit" in s), ("pipefail" in s)
    return None  # pwsh, python, cmd — not shell this gate understands


def add_steps(path, raw, steps, defaults_shell):
    for step in steps or []:
        if not isinstance(step, dict):
            continue
        script = step.get("run")
        if not isinstance(script, str):
            continue
        opts = shell_opts(step.get("shell", defaults_shell))
        if opts is None:
            continue
        e, p = opts
        se, sp = opts_from_script(script)
        units.append((path, locate(raw, script), script, e or se, p or sp, raw))


def locate(raw, script):
    """Line offset of a run block inside its file, or 0 when it is ambiguous."""
    first = next((ln for ln in script.split("\n") if ln.strip()), None)
    if first is None:
        return 0
    needle = first.strip()
    found = [i for i, ln in enumerate(raw.split("\n"), 1) if ln.strip() == needle]
    return found[0] - 1 if len(found) == 1 else 0


def anchor(raw, text, offset, lineno):
    """The file line to annotate.

    `yaml.safe_load` throws line numbers away, so a `run:` block's position has
    to be recovered from the text. Prefer the OFFENDING line itself — it is far
    more distinctive than the block's first line, which is `set -euo pipefail`
    in most blocks and therefore matches everywhere. An annotation with no line
    lands at the top of the file, which for a 900-line workflow is the
    difference between a fix and a search.
    """
    if offset:
        return offset + lineno
    hits = [i for i, ln in enumerate(raw.split("\n"), 1) if ln.strip() == text]
    return hits[0] if len(hits) == 1 else 0


wf = []
for pat in ("**/.github/workflows/*.yml", "**/.github/workflows/*.yaml",
            "**/action.yml", "**/action.yaml"):
    wf.extend(root.glob(pat))

for path in sorted(set(wf)):
    if ".git" in path.parts:
        continue
    try:
        raw = path.read_text(encoding="utf-8")
        doc = yaml.safe_load(raw)
    except Exception as exc:  # noqa: BLE001
        errors.append("%s: %s" % (path, " ".join(str(exc).split())[:200]))
        continue
    if not isinstance(doc, dict):
        continue
    top = ((doc.get("defaults") or {}).get("run") or {}).get("shell")
    jobs = doc.get("jobs")
    if isinstance(jobs, dict):
        for job in jobs.values():
            if not isinstance(job, dict):
                continue
            jd = ((job.get("defaults") or {}).get("run") or {}).get("shell") or top
            add_steps(path, raw, job.get("steps"), jd)
    runs = doc.get("runs")
    if isinstance(runs, dict) and isinstance(runs.get("steps"), list):
        add_steps(path, raw, runs["steps"], top)

for e in errors:
    print("::error::[PFR0] unreadable: %s" % e)

if not units:
    print("::error::[PFR0] no shell script or run: block under %s — the gate read nothing" % root)
    sys.exit(1)

fail = 1 if errors else 0
count = 0

for path, offset, script, errexit, pipefail, raw in units:
    for lineno, rule, name, text in findings(script, errexit, pipefail):
        count += 1
        fail = 1
        try:
            shown = path.relative_to(root).as_posix()
        except ValueError:
            shown = path.as_posix()
        absline = lineno if raw is None else anchor(raw, text, offset, lineno)
        where = ",line=%d" % absline if absline else ""
        if rule == "PFR3":
            print(
                "::error file=%s%s::[PFR3] `%s` ends this pipeline and its status IS the "
                "answer, while the writer is in-process: the reader exits on its first "
                "match, the writer dies of EPIPE, and pipefail turns a pipeline that FOUND "
                "its text into a false one. Use `grep -c ... >/dev/null` — it reads to end "
                "of input and still exits 1 when there is no match — or, for a line number, "
                "`... | cut -d: -f1 | sed -n 1p`. Offending line: %s"
                % (shown, where, name, text[:160])
            )
            continue
        print(
            "::error file=%s%s::[%s] `%s` ends this pipeline, and the block runs with "
            "-e and pipefail: the writer takes SIGPIPE, exits 141, and that becomes the "
            "status of the %s. Read all of the output and take what you want in the shell. "
            "Offending line: %s"
            % (shown, where, rule, name,
               "assignment" if rule == "PFR1" else "step",
               text[:160])
        )

print("checked %d shell unit(s) under %s — %d finding(s)" % (len(units), root, count))
sys.exit(fail)
PY
}

selftest() {
  local tmp out
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/.github/workflows"

  # A detector that sees nothing also reports PASS, so prove it fires first —
  # on the exact line that dequeued IntegrateIT #9321 twice.
  cat >"$tmp/bad.sh" <<'SH'
set -euo pipefail
got="$(terraform version | head -1)"
SH
  if out=$(scan "$tmp" 2>&1); then
    echo "::error::[PFR-SELFTEST] the gate PASSED an assignment ending in head under -e+pipefail" >&2
    return 1
  fi
  case "$out" in
    *"file=bad.sh,line=2"*"[PFR1]"*) : ;;
    *) echo "::error::[PFR-SELFTEST] expected a PFR1 annotation at bad.sh line 2, got: $out" >&2; return 1 ;;
  esac

  # …and that the fix silences it, so the gate is not simply always-red.
  cat >"$tmp/bad.sh" <<'SH'
set -euo pipefail
ver_out="$(terraform version)"
got="${ver_out%%$'\n'*}"
SH
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate FAILED the corrected form" >&2
    return 1
  fi

  # Without `-e` the 141 goes nowhere. Most gates in this repository are
  # written `set -uo pipefail` for exactly that reason, and flagging them would
  # make the rule a style preference rather than a correctness one.
  cat >"$tmp/bad.sh" <<'SH'
set -uo pipefail
got="$(printf '%s\n' "$x" | head -1)"
SH
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate FAILED a script with pipefail but no -e" >&2
    return 1
  fi

  # …and without pipefail the pipeline's status is head's, which is 0.
  cat >"$tmp/bad.sh" <<'SH'
set -eu
got="$(terraform version | head -1)"
SH
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate FAILED a script with -e but no pipefail" >&2
    return 1
  fi

  # `local` masks the substitution's status. Not this defect.
  cat >"$tmp/bad.sh" <<'SH'
set -euo pipefail
f() { local got="$(terraform version | head -1)"; echo "$got"; }
SH
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo '::error::[PFR-SELFTEST] the gate FAILED a "local" assignment' >&2
    return 1
  fi

  # An author who wrote `||` said the 141 will not CRASH the script, which is
  # all PFR1/PFR2 are about. It says nothing about the answer being right, which
  # is why the same `||` is what makes a PFR3 pipeline a verdict — so the writer
  # here is external, and the in-process one is asserted a few cases below.
  cat >"$tmp/bad.sh" <<'SH'
set -euo pipefail
grep -rn thing . | head -5 || true
grep -rlx "$m" . | grep -qx "$m" || { echo "missing: $m" >&2; exit 1; }
SH
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate FAILED a guarded pipeline" >&2
    return 1
  fi

  # A heredoc is data. This gate's own fixtures are heredocs full of the very
  # idiom it hunts, so reading one as code makes every such script self-report.
  cat >"$tmp/bad.sh" <<'OUTER'
set -euo pipefail
cat >/tmp/example <<'SH'
got="$(terraform version | head -1)"
SH
echo done
OUTER
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate read a heredoc body as code" >&2
    return 1
  fi

  # A bare pipeline statement is PFR2, and `grep -q` counts as a reader.
  cat >"$tmp/bad.sh" <<'SH'
set -euo pipefail
find . -type f | grep -q needle
SH
  if out=$(scan "$tmp" 2>&1); then
    echo "::error::[PFR-SELFTEST] the gate PASSED a bare pipeline ending in grep -q" >&2
    return 1
  fi
  case "$out" in
    *"[PFR2]"*) : ;;
    *) echo "::error::[PFR-SELFTEST] expected PFR2, got: $out" >&2; return 1 ;;
  esac

  # An `if` condition over an EXTERNAL writer stays out of scope. There is no
  # process inside this shell to kill, so nothing inverts — and this is the form
  # the repository is full of. It is the exemption most likely to be "fixed"
  # into a false-positive machine later.
  cat >"$tmp/bad.sh" <<'SH'
set -euo pipefail
if find . -type f | grep -q needle; then echo yes; fi
SH
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate FAILED an if-condition over an external writer" >&2
    return 1
  fi

  # PFR3, the shape that cost a CI run: an in-process writer feeding a reader
  # whose status is the answer. No `-e` here on purpose — the whole point is
  # that errexit is suspended in a condition and the 141 is read as `not found`.
  cat >"$tmp/bad.sh" <<'SH'
set -uo pipefail
if printf '%s\n' "$code" | grep -q 'needle'; then echo yes; fi
SH
  if out=$(scan "$tmp" 2>&1); then
    echo "::error::[PFR-SELFTEST] the gate PASSED an if-condition whose writer is a printf" >&2
    return 1
  fi
  case "$out" in
    *"file=bad.sh,line=2"*"[PFR3]"*) : ;;
    *) echo "::error::[PFR-SELFTEST] expected a PFR3 annotation at bad.sh line 2, got: $out" >&2; return 1 ;;
  esac

  # …and the `||` form, which the PFR1/PFR2 rules treat as a WAIVER of the
  # status and this one treats as a READ of it. Getting these two backwards is
  # the single most likely way to break the gate while it still looks correct.
  cat >"$tmp/bad.sh" <<'SH'
set -uo pipefail
check() { printf '%s\n' "$code" | grep -q 'needle' || return 1; }
SH
  if out=$(scan "$tmp" 2>&1); then
    echo "::error::[PFR-SELFTEST] the gate PASSED a printf | grep -q whose status feeds ||" >&2
    return 1
  fi
  case "$out" in
    *"[PFR3]"*) : ;;
    *) echo "::error::[PFR-SELFTEST] expected PFR3 for the || form, got: $out" >&2; return 1 ;;
  esac

  # A function defined in the same script is an in-process writer too — this is
  # the `code "$1" | grep -q ...` shape the self-tests in this directory use,
  # and the one that actually failed in CI.
  cat >"$tmp/bad.sh" <<'SH'
set -uo pipefail
code() { grep -v '^#' "$1"; }
has_thing() { code "$1" | grep -q 'thing' || return 1; }
SH
  if out=$(scan "$tmp" 2>&1); then
    echo "::error::[PFR-SELFTEST] the gate PASSED a shell function feeding grep -q" >&2
    return 1
  fi
  case "$out" in
    *"file=bad.sh,line=3"*"[PFR3]"*) : ;;
    *) echo "::error::[PFR-SELFTEST] expected PFR3 at bad.sh line 3, got: $out" >&2; return 1 ;;
  esac

  # NOT ONLY THE HEAD OF THE LIST. A condition's `&&` list reads the status of
  # every element, and a gate that inspects only the first one leaves the same
  # inversion sitting one segment further along — which is exactly where it was
  # found in shared-infra-band.selftest.sh.
  cat >"$tmp/bad.sh" <<'SH'
set -uo pipefail
if [ -n "$out" ] && printf '%s' "$out" | grep -q FAIL; then :; fi
SH
  if out=$(scan "$tmp" 2>&1); then
    echo "::error::[PFR-SELFTEST] the gate PASSED a verdict pipeline in the SECOND element of an && list" >&2
    return 1
  fi
  case "$out" in
    *"file=bad.sh,line=2"*"[PFR3]"*) : ;;
    *) echo "::error::[PFR-SELFTEST] expected PFR3 at bad.sh line 2 for the && list, got: $out" >&2; return 1 ;;
  esac

  # The recommended fixes must both be silent, or the gate has no landing place:
  # `grep -c ... >/dev/null` reads to end of input, and `sed -n 1p` keeps
  # reading where `head -1` would exit.
  cat >"$tmp/bad.sh" <<'SH'
set -uo pipefail
code() { grep -v '^#' "$1"; }
has_thing() { code "$1" | grep -c 'thing' >/dev/null || return 1; }
line_of() { printf '%s\n' "$1" | grep -n 'thing' | cut -d: -f1 | sed -n 1p; }
at() { grep -n -m1 'thing' "$1" | cut -d: -f1; }
SH
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate FAILED one of the fixes it recommends" >&2
    return 1
  fi

  # Without pipefail the pipeline's status is the READER's, which is 0 on a
  # match — nothing to invert. Most `run:` blocks with the default shell are
  # exactly this, so getting it wrong lights up the fleet.
  cat >"$tmp/bad.sh" <<'SH'
set -u
if printf '%s\n' "$code" | grep -q 'needle'; then echo yes; fi
SH
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate FAILED a printf | grep -q without pipefail" >&2
    return 1
  fi

  # A FILE argument has no writer to kill, even though the reader is the same
  # `grep -q` and the status is the same verdict. This is the exemption that
  # keeps the rule narrow enough to be worth having.
  cat >"$tmp/bad.sh" <<'SH'
set -uo pipefail
if grep -q 'needle' "$f" | cat; then echo yes; fi
if LC_ALL=C grep -qE "$re" "$f"; then echo yes; fi
SH
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate FAILED a grep with a file argument" >&2
    return 1
  fi

  # `shell: bash` carries -e AND pipefail without the block saying so. A reader
  # that only grepped for `set -euo pipefail` would call this clean.
  rm -f "$tmp/bad.sh"
  cat >"$tmp/.github/workflows/w.yml" <<'YML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - shell: bash
        run: |
          got="$(terraform version | head -1)"
          echo "$got"
YML
  if out=$(scan "$tmp" 2>&1); then
    echo "::error::[PFR-SELFTEST] the gate PASSED a shell: bash run block ending in head" >&2
    return 1
  fi
  case "$out" in
    *".github/workflows/w.yml"*"[PFR1]"*) : ;;
    *) echo "::error::[PFR-SELFTEST] expected a PFR1 annotation in the workflow, got: $out" >&2; return 1 ;;
  esac

  # The DEFAULT shell is `bash -e {0}` — errexit, no pipefail — so the same
  # block without `shell: bash` is out of scope. Getting this backwards would
  # make the gate fire on most of the fleet's workflows at once.
  cat >"$tmp/.github/workflows/w.yml" <<'YML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          got="$(terraform version | head -1)"
          echo "$got"
YML
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate FAILED a default-shell block, which has no pipefail" >&2
    return 1
  fi

  # A pwsh block is not shell this gate understands, and must not be read as one.
  # The clean script is here so that "skipped the pwsh block" cannot be confused
  # with "found nothing to read", which is also a failure.
  cat >"$tmp/clean.sh" <<'SH'
set -euo pipefail
echo hello
SH
  cat >"$tmp/.github/workflows/w.yml" <<'YML'
name: w
on: [push]
jobs:
  j:
    runs-on: windows-latest
    steps:
      - shell: pwsh
        run: |
          $got = terraform version | Select-Object -First 1
YML
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate read a pwsh block as bash" >&2
    return 1
  fi

  # Reading nothing is an error, not a pass.
  rm -rf "$tmp/.github" "$tmp/clean.sh"
  if scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PFR-SELFTEST] the gate PASSED with nothing to read" >&2
    return 1
  fi

  echo "selftest ok"
  return 0
}

if [ "$SELFTEST" = 1 ]; then
  selftest
  exit $?
fi

scan "$ROOT"
