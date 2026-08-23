#!/usr/bin/env bash
# =============================================================================
# check-workflow-shell.sh — a `run:` block is shell, and shell is checked
#
# USAGE
#   bash scripts/ci/check-workflow-shell.sh [--selftest] [--root=<dir>]
#                                           [--exclude=SC****]... [<file>...]
#
# PURPOSE
#   Every `run:` block in a workflow or a composite action is extracted and put
#   through `bash -n` and shellcheck, at its real file and line.
#
#     WFS1  the block parses as shell
#     WFS2  shellcheck has nothing to say about it
#     WFS0  the gate could not read a document, could not find shellcheck, or
#           found nothing to check — reported, never passed
#
# WHY (issue #68)
#   The `shell` job shellchecks every `*.sh` in the tree. A composite action's
#   `run:` blocks are shell that lives in a `.yml`, and nothing read them: an
#   entire class of shell in this repository was out of the tool's reach while
#   the same pull requests had real shellcheck findings in their `.sh` files.
#
#   The shape of the miss is what makes it worth a gate rather than a habit.
#   This repository publishes actions and workflow fragments that run in
#   CONSUMERS' repositories, on their warm hosts, holding their job identity. A
#   quoting bug there first shows up in somebody else's pull request, in a
#   repository whose owner did not write the line — the least convenient place
#   for it to surface and the hardest to attribute.
#
# WHY NOT actionlint
#   actionlint does this natively and validates the workflow schema too, and it
#   is the right answer for a repository that only needs to check itself. This
#   one publishes its gates: fourteen repositories adopt them BY TAG, as shell
#   they source, next to `lane-decision.sh` and `check-action-pins.sh` — which
#   already parse workflow YAML for exactly this reason. A Go binary downloaded
#   per consumer is a second supply chain to pin, in a fleet where an unpinned
#   third-party artefact is the thing `check-action-pins.sh` exists to forbid.
#   The schema half of actionlint remains worth having and is not this gate.
#
# HOW THE LINE NUMBERS STAY TRUE
#   A finding reported against a scratch file is a finding nobody fixes. Each
#   extracted block is written into a temporary file padded with blank lines, so
#   that line N of the temporary file IS line N of the YAML, and every message
#   is rewritten to name the real path.
#
#   That alignment is exact for a literal block scalar (`run: |`), which is what
#   essentially every multi-line `run:` is, because YAML strips the block indent
#   and keeps the line breaks. For a FOLDED (`>`) or plain multi-line scalar the
#   line breaks are rewritten by YAML itself, so the mapping cannot be exact;
#   those findings are reported at the block's first line and SAY SO, rather
#   than pointing confidently at the wrong line.
#
# WHAT IS NOT CHECKED, AND WHY EACH EXEMPTION IS NARROW
#   * A block whose `shell:` is not bash or sh — `pwsh`, `python`, `cmd`. Not
#     shell, so shellcheck's verdict on it would be noise.
#   * A block in a job whose `runs-on` names Windows and which does not declare
#     `shell: bash`. GitHub's default shell there is `pwsh`, so reading it as
#     bash would invent findings about a file that is not bash. This fleet runs
#     Windows pools, so this is a real case and not a hypothetical one.
#   * `${{ … }}` is replaced, character for character, by a filler before the
#     block is parsed. It is not shell — it is substituted BEFORE the shell sees
#     it — and leaving it in makes the parse fail on a construct that is not the
#     author's. Same length, so columns still point at the right place.
#
#   Everything else is checked, including every block in `.github/actions/**`,
#   which is the class the gate was written for.
#
# WHY A MISSING SHELLCHECK IS WFS0 AND NOT A PASS
#   A gate that quietly does nothing when its tool is absent reports clean on
#   every run and reads as adopted. That is the vacuous pass this repository's
#   config gates are all arranged against, so the absence is an error here — and
#   in the self-test too, which is why `--allow-missing-shellcheck` exists and
#   why CI never passes it.
#
# EXIT CODES
#   0 — clean
#   1 — a finding, or a document/tool the gate could not read
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$REPO_ROOT"

fail=0
err() { local id="$1"; shift; echo "::error::[$id] $*"; fail=1; }

# SC1090/SC1091 — a sourced path is resolved at runtime on the VM, exactly as in
#   the `*.sh` scan this gate sits beside.
# SC2154 — "referenced but not assigned". Inside a `run:` block, unassigned is
#   the NORMAL case: `$GITHUB_OUTPUT`, `$RUNNER_TEMP` and every `env:` value
#   arrive from the runner, not from the block. Left on, this one code would
#   outnumber every real finding and the gate would be switched off.
# SC2148 — no shebang. There cannot be one; the shell is declared in YAML, and
#   this gate passes it to shellcheck with `-s`.
EXCLUDE_DEFAULT='SC1090,SC1091,SC2154,SC2148'
ALLOW_MISSING_SHELLCHECK=0

export PY_BIN="${PY_BIN:-}"
py_usable() {
  command -v "$1" >/dev/null 2>&1 &&
    "$1" -c 'import sys, yaml; sys.exit(0 if sys.version_info >= (3, 7) else 1)' >/dev/null 2>&1
}

ensure_yaml() {
  local c
  if [ -n "$PY_BIN" ]; then
    py_usable "$PY_BIN" && return 0
    PY_BIN=""
  fi
  for c in python3 /usr/bin/python3 /usr/bin/python /usr/local/bin/python3 python; do
    if py_usable "$c"; then
      PY_BIN="$c"
      return 0
    fi
  done
  return 1
}

# Emits one record per `run:` block:
#
#   #ERR\t<message>
#   #RUN\t<job>\t<where>\t<first content line>\t<exact:0|1>\t<shell>\t<base64 script>
#   #SKIP\t<job>\t<where>\t<reason>
#
# `yaml.compose` rather than `safe_load`, because `safe_load` throws the line
# numbers away and a finding without one is a finding nobody acts on.
read_runs() {
  "${PY_BIN:-python3}" - "$1" <<'PY'
import base64, sys, yaml

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(newline="\n")


def out(*fields):
    print("\t".join(str(f).replace("\t", " ").replace("\n", " ") for f in fields))


def mapping(node):
    """{key: value-node} for a MappingNode, or {} for anything else."""
    if not isinstance(node, yaml.MappingNode):
        return {}
    got = {}
    for k, v in node.value:
        if isinstance(k, yaml.ScalarNode):
            got[k.value] = v
    return got


def sequence(node):
    return node.value if isinstance(node, yaml.SequenceNode) else []


def scalar(node):
    return node.value if isinstance(node, yaml.ScalarNode) else None


def default_shell(node):
    """`defaults.run.shell`, at the workflow or the job level."""
    return scalar(mapping(mapping(mapping(node).get("defaults")).get("run")).get("shell"))


def runs_on_text(job):
    """`runs-on` flattened to text — enough to spot a Windows label."""
    node = mapping(job).get("runs-on")
    if node is None:
        return ""
    if isinstance(node, yaml.ScalarNode):
        return node.value or ""
    if isinstance(node, yaml.SequenceNode):
        return " ".join(str(scalar(n) or "") for n in node.value)
    if isinstance(node, yaml.MappingNode):
        # `runs-on: {group: …, labels: […]}`
        parts = []
        for key, sub in mapping(node).items():
            if isinstance(sub, yaml.ScalarNode):
                parts.append(sub.value or "")
            else:
                parts.extend(str(scalar(n) or "") for n in sequence(sub))
            parts.append(str(key))
        return " ".join(parts)
    return ""


def emit_step(job_id, index, step, inherited_shell, windows):
    fields = mapping(step)
    run = fields.get("run")
    if not isinstance(run, yaml.ScalarNode) or run.value is None:
        return
    where = "step %d" % index

    declared = scalar(fields.get("shell"))
    shell = declared or inherited_shell or ("pwsh" if windows else "bash")
    base = shell.split()[0] if shell else "bash"
    if base not in ("bash", "sh"):
        out("#SKIP", job_id, where, "shell is %r" % shell)
        return

    # `|` keeps the line breaks the file has, so the mapping is exact. A folded
    # or plain scalar has had its breaks rewritten by YAML before this gate ever
    # sees it; a single-line one has no breaks to rewrite, so it is exact too.
    style = getattr(run, "style", None)
    exact = 1 if (style == "|" or "\n" not in run.value) else 0
    first = run.start_mark.line + (2 if style in ("|", ">") else 1)

    out("#RUN", job_id, where, first, exact, base,
        base64.b64encode(run.value.encode("utf-8")).decode("ascii"))


try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = yaml.compose(fh)
except Exception as exc:  # noqa: BLE001
    out("#ERR", " ".join(str(exc).split())[:400])
    sys.exit(0)

if doc is None:
    out("#ERR", "empty document")
    sys.exit(0)

top = mapping(doc)
if not top:
    out("#ERR", "document is not a mapping")
    sys.exit(0)

workflow_shell = default_shell(doc)

jobs = top.get("jobs")
if isinstance(jobs, yaml.MappingNode):
    for job_key, job in jobs.value:
        job_id = scalar(job_key) or "?"
        windows = "windows" in runs_on_text(job).lower()
        inherited = default_shell(job) or workflow_shell
        for i, step in enumerate(sequence(mapping(job).get("steps"))):
            emit_step(job_id, i, step, inherited, windows)

# A composite action has no `jobs:`. Its `run:` blocks execute on the CALLING
# job's runner — in a consumer's repository — which is the whole reason this
# gate exists.
runs = top.get("runs")
if isinstance(runs, yaml.MappingNode):
    for i, step in enumerate(sequence(mapping(runs).get("steps"))):
        # A composite step MUST declare `shell:`; there is no runner default to
        # inherit, so nothing is passed as inherited and an undeclared one falls
        # through to bash — which is what GitHub rejects the action for anyway.
        emit_step("runs", i, step, None, False)
PY
}

# `${{ … }}` out, filler in, character for character. It is substituted before
# the shell ever runs, so leaving it in makes the parse fail on a construct the
# author did not write — while replacing it with something SHORTER moves every
# column after it.
strip_expressions() {
  # `-c`, not `-` reading the program from stdin: with `python3 -` the program
  # IS stdin, so `sys.stdin.read()` returns the empty string and every block
  # arrives at the checker blank — a gate that reports clean on an empty file it
  # emptied itself.
  # shellcheck disable=SC2016  # the python program must NOT be shell-expanded.
  "${PY_BIN:-python3}" -c '
import re, sys

if hasattr(sys.stdin, "reconfigure"):
    sys.stdin.reconfigure(newline="")
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(newline="")

text = sys.stdin.read()


def filler(match):
    # Newlines are kept so the line count cannot change; everything else becomes
    # an inert word character. Spelled `chr(10)` rather than as an escape: this
    # program travels through a shell quote, and a backslash escape in here is
    # one editor away from becoming a literal line break in the middle of a
    # string.
    return "".join(c if c == chr(10) else "X" for c in match.group(0))


sys.stdout.write(re.sub(r"\$\{\{.*?\}\}", filler, text, flags=re.S))
'
}

# --- one block ---------------------------------------------------------------
check_block() {
  local rel="$1" job="$2" where="$3" first="$4" exact="$5" shell="$6" b64="$7"
  local tmp script note="" line out_text

  tmp="$(mktemp)"
  # Pad so line N of this file is line N of the YAML.
  awk -v n=$((first - 1)) 'BEGIN { while (n-- > 0) print "" }' > "$tmp"
  script="$(printf '%s' "$b64" | base64 -d 2>/dev/null | strip_expressions)"
  printf '%s\n' "$script" >> "$tmp"

  [ "$exact" = "1" ] || note=" (folded or plain scalar — YAML rewrote the line breaks, so this points at the block, not the line)"

  # WFS1 — does it parse at all. Cheap, and a syntax error makes every
  # downstream shellcheck message noise.
  #
  # (Word order is load-bearing: a comment line beginning `# shellcheck ` IS a
  # directive, and shellcheck rejected the earlier phrasing as an unparseable
  # one — in this file, of all files. Caught by the gate one step above.)
  if ! out_text="$("$shell" -n "$tmp" 2>&1)"; then
    err WFS1 "$rel: job '$job' $where does not parse as $shell$note: $(printf '%s' "$out_text" | sed "s#$tmp#$rel#g" | head -3 | tr '\n' ' ')"
    rm -f "$tmp"
    return
  fi

  # WFS2 — and what shellcheck makes of it. `-f gcc` is the one format whose
  # `file:line:col:` prefix can be rewritten back onto the YAML.
  #
  # The guard is for the SELF-TEST only: on the real path `main` refuses to run
  # at all without shellcheck, because a gate that skips its own tool reports
  # clean forever.
  if ! command -v shellcheck >/dev/null 2>&1; then
    rm -f "$tmp"
    return
  fi
  out_text="$(shellcheck -s "$shell" -f gcc -e "$EXCLUDE_DEFAULT" "$tmp" 2>&1)"
  if [ -n "$out_text" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      err WFS2 "$(printf '%s' "$line" | sed "s#^$tmp#$rel#")$note"
    done <<EOF
$out_text
EOF
  fi

  rm -f "$tmp"
}

# --- one document ------------------------------------------------------------
check_file() {
  local file="$1" rel records status job where first exact shell b64
  rel="${file#"$ROOT"/}"

  records="$(read_runs "$file")"
  status=$?
  # The reader's EXIT STATUS, not only its output: killed or dying on an
  # interpreter fault it emits no `#ERR` and no records, and an empty record set
  # is indistinguishable from a document with no `run:` blocks.
  if [ "$status" -ne 0 ]; then
    err WFS0 "$rel: the YAML reader exited $status without a verdict — treating as unreadable rather than clean"
    return
  fi

  if printf '%s\n' "$records" | grep -c '^#ERR	' >/dev/null; then
    err WFS0 "$rel: $(printf '%s\n' "$records" | sed -n 's/^#ERR\t//p' | head -1)"
    return
  fi

  while IFS=$'\t' read -r _ job where first exact shell b64; do
    [ -n "${b64:-}" ] || continue
    check_block "$rel" "$job" "$where" "$first" "$exact" "$shell" "$b64"
    BLOCKS=$((BLOCKS + 1))
  done <<EOF
$(printf '%s\n' "$records" | grep '^#RUN	')
EOF
}

BLOCKS=0

# --- fixtures ----------------------------------------------------------------
#
# shellcheck disable=SC2030  # each expectation scores inside `$( )` with its own
# `fail=0`; the subshell IS the isolation.
selftest() {
  local tmp status=0
  tmp="$(mktemp -d)"
  ROOT="$tmp"

  expect() {
    local name="$1" want="$2" body="$3" f="$tmp/wf.yml"
    local got out_text
    printf '%s\n' "$body" > "$f"
    out_text="$(fail=0; check_file "$f" 2>&1)"
    got="$(printf '%s\n' "$out_text" | sed -n 's/.*::error::\[\([A-Z0-9]*\)\].*/\1/p' | sort -u | tr '\n' ' ')"
    got="$(printf '%s' "$got" | sed 's/ *$//')"
    if [ "$got" != "$want" ]; then
      echo "FAIL $name: want ids [$want], got [$got]"
      printf '%s\n' "$out_text" | sed 's/^/      /'
      status=1
    else
      echo "ok   $name [$want]"
    fi
  }

  # --- WFS1: it has to parse -------------------------------------------------
  # shellcheck disable=SC2016  # the fixture is YAML; every `$` in it is data.
  expect "a syntax error in a run: block" "WFS1" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo one
          if [ -z "$x" ]; then
            echo two'

  expect "a clean block is clean" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          set -euo pipefail
          echo "hello"'

  # THE headline case of issue #68: a composite action has no `jobs:`, and every
  # reader in this repository that stopped at `jobs:` called it clean.
  # shellcheck disable=SC2016  # the fixture is YAML; every `$` in it is data.
  expect "a composite action's run: block is read" "WFS1" \
'name: playwright-ui
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        for f in *.txt do
          echo "$f"
        done'

  # --- the exemptions, each asserted so that widening one is a visible change --
  expect "a pwsh step is not bash" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - shell: pwsh
        run: |
          if ( -z ) { oops'

  expect "a windows job defaults to pwsh, not bash" "" \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, windows]
    steps:
      - run: |
          if ( -z ) { oops'

  # …and the half that keeps that exemption from becoming a hole: an explicit
  # `shell: bash` on a Windows runner IS bash, and is checked.
  expect "an explicit bash on a windows job is still checked" "WFS1" \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, windows]
    steps:
      - shell: bash
        run: |
          echo "unterminated'

  expect "a workflow-level default shell is inherited" "WFS1" \
'on: [push]
defaults:
  run:
    shell: bash
jobs:
  build:
    runs-on: [self-hosted, windows]
    steps:
      - run: |
          echo "unterminated'

  # An expression is not shell. Left in place it fails the PARSE, which would
  # make this gate report a finding about a construct nobody wrote — the class
  # of false positive that gets a gate deleted rather than fixed.
  # shellcheck disable=SC2016  # the fixture IS the unexpanded `${{ … }}` text.
  expect "a github expression does not break the parse" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "ref is ${{ github.ref }}"
          test "${{ github.event_name }}" = push'

  # --- WFS0 ------------------------------------------------------------------
  expect "an unparseable document" "WFS0" \
'jobs: [ unterminated'

  # --- the line mapping ------------------------------------------------------
  #
  # A finding reported at the wrong line is a finding somebody looks for and
  # cannot find. The `for` below is on line 8 of the fixture and bash reports the
  # line it chokes on, which is the one after it — so the message must carry 9,
  # a number that only comes out right if the padding is exact.
  # shellcheck disable=SC2016  # the fixture is YAML; every `$` in it is data.
  printf '%s\n' 'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo one
          for f in *.txt do
            echo "$f"
          done' > "$tmp/wf.yml"
  local mapped
  mapped="$(fail=0; check_file "$tmp/wf.yml" 2>&1)"
  if printf '%s' "$mapped" | grep -c 'wf\.yml: line 9' >/dev/null; then
    echo "ok   a finding names its real line"
  else
    echo "FAIL a finding names its real line: expected 'wf.yml: line 9' in:"
    printf '%s\n' "$mapped" | sed 's/^/      /'
    status=1
  fi

  # --- shellcheck, which is the other half of the gate -----------------------
  if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # the fixture is YAML; every `$` in it is data.
    expect "an unquoted expansion is a shellcheck finding" "WFS2" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          f=$1
          rm $f'

    # shellcheck disable=SC2016  # the fixture is YAML; every `$` in it is data.
    expect "an inline shellcheck directive is honoured" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          # shellcheck disable=SC2086
          f=$1
          rm $f'

    # SC2154 is excluded on purpose: inside a `run:` block every `env:` value
    # and every `$GITHUB_*` arrives from the runner, so leaving it on would
    # bury the real findings under one code.
    # shellcheck disable=SC2016  # the fixture is YAML; every `$` in it is data.
    expect "a runner-supplied variable is not an unassigned one" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "out=1" >> "$GITHUB_OUTPUT"'
  elif [ "$ALLOW_MISSING_SHELLCHECK" -eq 1 ]; then
    echo "note shellcheck is absent — its three fixtures did not run (declared with --allow-missing-shellcheck)"
  else
    echo "FAIL shellcheck is not installed, so half this gate was never exercised — a self-test that skips its own tool is the vacuous pass it exists to prevent (pass --allow-missing-shellcheck to declare that you know)"
    status=1
  fi

  rm -rf "$tmp"
  return "$status"
}

# --- discovery ---------------------------------------------------------------
discover() {
  { find "$ROOT/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
    find "$ROOT/.github/actions" -type f \( -name 'action.yml' -o -name 'action.yaml' \) 2>/dev/null
  } | sort
}

# shellcheck disable=SC2031  # `fail` is read after the fixtures wrote their own
# copies inside subshells — intended. On the real path `check_file` runs here.
main() {
  local run_selftest=0 arg
  local -a files=()

  for arg in "$@"; do
    case "$arg" in
      --selftest)  run_selftest=1 ;;
      --root=*)    ROOT="${arg#--root=}" ;;
      --exclude=*) EXCLUDE_DEFAULT="$EXCLUDE_DEFAULT,${arg#--exclude=}" ;;
      --allow-missing-shellcheck) ALLOW_MISSING_SHELLCHECK=1 ;;
      -*)          echo "::error::[WFS0] unknown option: $arg"; return 1 ;;
      *)           files+=("$arg") ;;
    esac
  done

  if ! ensure_yaml; then
    echo "::error::[WFS0] no Python with PyYAML available; this gate cannot read a workflow"
    return 1
  fi

  if [ "$run_selftest" -eq 1 ]; then
    selftest
    return
  fi

  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "::error::[WFS0] shellcheck is not installed — this gate would report clean without checking anything"
    return 1
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    while IFS= read -r arg; do
      [ -n "$arg" ] || continue
      files+=("$arg")
    done <<EOF
$(discover)
EOF
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    echo "::error::[WFS0] no workflow or action manifest found — nothing was checked"
    return 1
  fi

  for arg in "${files[@]}"; do
    check_file "$arg"
  done

  # Zero blocks across every document is not a clean tree either: it is the
  # reader having failed to find a key it was looking for, which is how a parser
  # change turns this gate off without failing it.
  if [ "$BLOCKS" -eq 0 ]; then
    echo "::error::[WFS0] ${#files[@]} document(s) read and not one run: block extracted — the reader found nothing to check"
    return 1
  fi

  if [ "$fail" -eq 0 ]; then
    echo "workflow shell clean: $BLOCKS run: block(s) in ${#files[@]} document(s)"
  fi
  return "$fail"
}

main "$@"
