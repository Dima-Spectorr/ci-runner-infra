#!/usr/bin/env bash
# =============================================================================
# check-packer-inline-shell.sh — an inline provisioner runs under the shebang,
#                                not under execute_command
#
# USAGE
#   bash scripts/ci/check-packer-inline-shell.sh [--selftest] [--root=<dir>]
#
# PURPOSE
#   Every `provisioner "shell"` block with an `inline` list is checked: if its
#   script uses a bash-only construct, it must declare an `inline_shebang` that
#   names bash.
#
#   The ids name the RULE, and are REPORTED when the rule is broken — the same
#   shape as WFS1/WFS0 in check-workflow-shell.sh:
#
#     PIS1  an inline block using a bashism declares a bash inline_shebang
#           (reported at the offending line when it does not)
#     PIS0  the gate could not read a template, or found no inline provisioner,
#           or has no python3 to read them with — reported, never passed
#
# WHY
#   `execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"` reads as
#   "this runs under bash". It does not. Packer writes the inline block to a
#   file and execute_command runs that file as a COMMAND, so the kernel honours
#   the file's shebang — and the shebang is `inline_shebang`, whose default is
#   `/bin/sh -e`. On Ubuntu that is dash.
#
#   Every provisioner in ci-host-image.pkr.hcl said `set -eux`, which dash
#   accepts, so the default held for a year and read as deliberate. The first
#   block to need `pipefail` — the warm-cache seal, which needs it because
#   without it a `find` that errors still passes its guard — died with
#
#     /tmp/script_3436.sh: 2: set: Illegal option -o pipefail
#
#   four minutes into a forty-minute image build, and only for whoever built an
#   image next. No consumer's CI failed, because building an image is not part
#   of any consumer's CI. That is the shape worth a gate: a `bash` in the block
#   right below the defect, and a failure that surfaces days later to somebody
#   who did not write the line.
#
# WHY NOT `packer validate`
#   It parses the HCL, which is exactly the half that is already valid here. The
#   shebang question is about what the guest kernel does with the uploaded file,
#   and no amount of template validation reaches it.
#
# EXIT CODES
#   0 — clean
#   1 — a block using a bashism without a bash inline_shebang, or nothing found
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
  # Named, not inherited from `command not found`. A gate that cannot run its
  # own reader must say so in its own vocabulary, or the failure reads as "the
  # script is broken" rather than "this runner has no python3" — and on a
  # runner where the tool is genuinely absent, a generic 127 is the shape that
  # gets "fixed" by making the step non-blocking.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "::error::[PIS0] python3 is not on PATH — the gate has no reader, so it checked nothing"
    return 1
  fi

  python3 - "$1" <<'PY'
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])
files = sorted(root.rglob("*.pkr.hcl"))
if not files:
    print("::error::[PIS0] no *.pkr.hcl under %s — the gate read nothing" % root)
    sys.exit(1)

# Constructs dash does not have. Deliberately short: every entry here must be
# unambiguous in a shell script, because a false positive on a gate nobody can
# silence is how a gate gets deleted.
BASHISMS = [
    (r"\bset\s+[-\w]*o\s+pipefail\b", "set -o pipefail"),
    (r"\[\[", "[[ … ]]"),
    (r"<\(", "process substitution <(…)"),
    (r"\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}", "array expansion"),
    (r"\blocal\s+-n\b", "local -n (nameref)"),
]

fail = 0
checked = 0

for path in files:
    text = path.read_text(encoding="utf-8")
    # Walk each `provisioner "shell" {` to its matching close brace. Brace
    # counting, not a regex: the block contains braces of its own (${…}, find
    # -exec {} +) and a lazy regex would end the block at the first one.
    for m in re.finditer(r'provisioner\s+"shell"\s*\{', text):
        depth = 0
        i = m.end() - 1
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        block = text[m.start():i + 1]
        line0 = text[:m.start()].count("\n") + 1

        if not re.search(r"^\s*inline\s*=", block, re.M):
            continue  # a `scripts = [...]` provisioner carries its own shebang
        checked += 1

        shebang = re.search(r'inline_shebang\s*=\s*"([^"]*)"', block)
        is_bash = bool(shebang) and "bash" in shebang.group(1)

        for pattern, name in BASHISMS:
            hit = re.search(pattern, block)
            if not hit:
                continue
            if is_bash:
                continue
            hitline = line0 + block[:hit.start()].count("\n")
            # Relative to the scanned root, which in CI is the checkout: an
            # absolute path in a workflow annotation does not resolve to a file
            # in the diff, so the finding stops appearing on the line it is
            # about and becomes a log message nobody scrolls to.
            try:
                shown = path.relative_to(root).as_posix()
            except ValueError:
                shown = path.as_posix()
            print(
                "::error file=%s,line=%d::[PIS1] inline provisioner uses %s but "
                "declares no bash inline_shebang, so it runs under the default "
                "/bin/sh (dash) and dies at that line. Add: "
                'inline_shebang = "/bin/bash -e"'
                % (shown, hitline, name)
            )
            fail = 1
            break

if checked == 0:
    print("::error::[PIS0] no inline shell provisioner found — the gate read nothing")
    sys.exit(1)

print("checked %d inline shell provisioner(s) across %d template(s)" % (checked, len(files)))
sys.exit(fail)
PY
}

selftest() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/packer"

  # A detector that sees nothing also reports PASS, so prove it fires first.
  cat >"$tmp/packer/bad.pkr.hcl" <<'HCL'
build {
  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      "echo hello",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }
}
HCL
  local out
  if out=$(scan "$tmp" 2>&1); then
    echo "::error::[PIS-SELFTEST] the gate PASSED a pipefail block with no bash shebang" >&2
    return 1
  fi

  # The annotation has to land ON the line, which means a path relative to the
  # scanned root. An absolute one still prints, still says the right thing, and
  # silently stops being a finding attached to the diff — so the shape of the
  # message is asserted, not just the exit code.
  case "$out" in
    *"file=packer/bad.pkr.hcl,line=4"*) : ;;
    *)
      echo "::error::[PIS-SELFTEST] expected an annotation at file=packer/bad.pkr.hcl,line=4, got: $out" >&2
      return 1
      ;;
  esac

  # …and that the fix silences it, so the gate is not simply always-red.
  cat >"$tmp/packer/bad.pkr.hcl" <<'HCL'
build {
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "set -euxo pipefail",
      "echo hello",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }
}
HCL
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PIS-SELFTEST] the gate FAILED a block that declares a bash shebang" >&2
    return 1
  fi

  # A dash-safe block must stay clean without needing a shebang at all — the
  # gate must not become "every provisioner declares bash", which would make it
  # a style rule rather than a correctness one.
  cat >"$tmp/packer/bad.pkr.hcl" <<'HCL'
build {
  provisioner "shell" {
    inline = [
      "set -eux",
      "find /opt -type d -exec chmod 0755 {} +",
    ]
    execute_command = "sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
  }
}
HCL
  if ! scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PIS-SELFTEST] the gate FAILED a dash-safe block" >&2
    return 1
  fi

  # Reading nothing is an error, not a pass.
  rm -f "$tmp/packer/bad.pkr.hcl"
  if scan "$tmp" >/dev/null 2>&1; then
    echo "::error::[PIS-SELFTEST] the gate PASSED with no template to read" >&2
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
