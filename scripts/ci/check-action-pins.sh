#!/usr/bin/env bash
# =============================================================================
# check-action-pins.sh — a third-party action is code, and code is pinned
#
# USAGE
#   bash scripts/ci/check-action-pins.sh [--selftest] [--allow=<owner>]... [<file>...]
#
# PURPOSE
#   Every `uses:` that leaves this repository must name an immutable commit,
#   not a tag or a branch.
#
#     PIN1  a remote `uses:` is pinned to a 40-character commit SHA
#     PIN2  and carries the human-readable version beside it, as a comment
#     PIN3  a `docker://` step image is pinned by digest, not by tag
#
# WHY
#   `@v4` is a tag, and a tag is a pointer its owner may move at any time. The
#   audit behind `docs/ci-optimization-catalog.md` §7 measured ZERO of ~375
#   third-party action references pinned by SHA across fourteen repositories —
#   and on this fleet those actions execute on warm GCP VMs that hold a service
#   identity, beside other jobs' caches and checked-out trees. One moved tag on
#   one popular action is arbitrary code on every pool in the fleet, with no
#   pull request in any consuming repository to review it.
#
#   The second reason is duller and pays every week: a moved tag is also the
#   surprise-breakage class of CI failure — a green pipeline goes red with no
#   change in the repository, which is a full diagnosis cycle spent on somebody
#   else's release. Pinning converts that into a Dependabot pull request.
#
# WHY PIN2 IS NOT DECORATION
#   `actions/checkout@11bd719` tells a reviewer nothing about what it is or
#   whether it is current, so a SHA-only pin buys immutability by giving up
#   reviewability — and the usual next step is that nobody upgrades it for two
#   years. The comment (`@<sha> # v4.2.2`) is what Dependabot itself writes and
#   what it rewrites on every bump, so requiring it costs nothing and keeps the
#   diff readable. It is asserted against the RAW LINE, because a comment is not
#   part of the loaded document.
#
# WHAT IS NOT CHECKED
#   A `uses:` beginning `./` is this repository's own tree at this repository's
#   own commit — already immutable, and pinning it to a SHA is not expressible.
#   `--allow=<owner>` exempts an owner a consumer has decided to trust by tag;
#   it exists so that adopting this gate is never all-or-nothing, and every use
#   of it is a visible argument in the consuming workflow rather than a silent
#   default here.
#
# WHY COMPOSITE ACTIONS ARE SCANNED TOO
#   Exempting `./.github/actions/setup` is right — and it was also a hole. That
#   action's own `action.yml` may `uses: third/party@main`, which then executes
#   inside the calling job, on the calling job's runner, with the calling job's
#   token. The exemption was reading "local, therefore immutable" when what is
#   local is only the WRAPPER. So discovery covers `.github/actions/**` manifests
#   as well as `.github/workflows/*`, and the parser reads `runs.steps[].uses`
#   for a document that has no `jobs:`.
#
# EXIT CODES
#   0 — clean
#   1 — an unpinned reference
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0
err() { local id="$1"; shift; echo "::error::[$id] $*"; fail=1; }

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

# Emits one record per reference:
#
#   #ERR\t<message>
#   #USES\t<job>\t<step index or "-">\t<reference>
#
# Read from the loaded document rather than by grepping `uses:`, because a
# `uses:` inside a `run:` heredoc, inside a `with:` value, or in a comment is
# not a reference GitHub resolves — and a gate that fails a repository for a
# string in a shell script is a gate that gets deleted.
read_uses() {
  "${PY_BIN:-python3}" - "$1" <<'PY'
import sys, yaml

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(newline="\n")


def out(*fields):
    print("\t".join(str(f).replace("\t", " ").replace("\n", " ") for f in fields))


try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except Exception as exc:  # noqa: BLE001
    out("#ERR", " ".join(str(exc).split())[:400])
    sys.exit(0)

if not isinstance(doc, dict):
    out("#ERR", "workflow is not a mapping")
    sys.exit(0)

jobs = doc.get("jobs")
if not isinstance(jobs, dict):
    # No `jobs:` — this may be a composite action manifest, whose `runs.steps`
    # execute on the CALLING job's runner with the calling job's token. A local
    # `uses:` is exempt from pinning because the wrapper is immutable; what the
    # wrapper then reaches for is not.
    runs = doc.get("runs")
    if isinstance(runs, dict) and isinstance(runs.get("steps"), list):
        for i, step in enumerate(runs["steps"]):
            if isinstance(step, dict) and isinstance(step.get("uses"), str):
                out("#USES", "runs", i, step["uses"].strip())
    sys.exit(0)

for job_id, job in jobs.items():
    if not isinstance(job, dict):
        continue
    # A job-level `uses:` calls a reusable workflow. It is the same question:
    # `owner/repo/.github/workflows/x.yml@main` is a branch, and the workflow
    # behind it changes under every consumer at once.
    if isinstance(job.get("uses"), str):
        out("#USES", job_id, "-", job["uses"].strip())
    steps = job.get("steps")
    if not isinstance(steps, list):
        continue
    for i, step in enumerate(steps):
        if isinstance(step, dict) and isinstance(step.get("uses"), str):
            out("#USES", job_id, i, step["uses"].strip())
PY
}

# A 40-hex commit. Not `[0-9a-f]{7,}` — an abbreviated SHA is ambiguous by
# construction and GitHub resolves it against whatever the repository holds at
# resolution time, which is the mutability this gate exists to remove. Hex is
# case-insensitive: git writes lowercase, but a pin pasted uppercase is still a
# pin, and failing it would be this gate reporting on a house style.
SHA_RE='^[0-9a-fA-F]{40}$'

# `grep -E` metacharacters in a value that is about to become a pattern. Action
# paths carry `.` routinely (`owner/action.js`), and unescaped that matches any
# character — which reads as MORE lines matching, i.e. in the passing direction.
re_quote() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\\\/]/\\&/g'; }

check_file() {
  local file="$1" rel records status job step ref owner path version
  shift
  local -a allow=("$@")
  rel="${file#"$REPO_ROOT"/}"

  # The parser's exit status, not just its output. Killed by the OOM killer or
  # dying on an interpreter-level fault, it emits no `#ERR` and no records — and
  # an empty record set is indistinguishable from a clean file. That is the
  # vacuous pass this gate's whole design is arranged against, so it is caught
  # here rather than trusted.
  records="$(read_uses "$file")"
  status=$?
  if [ "$status" -ne 0 ]; then
    err PIN0 "$rel: the YAML reader exited $status without a verdict — treating as unreadable rather than clean"
    return
  fi

  if [ "$(printf '%s\n' "$records" | grep -c '^#ERR	')" -gt 0 ]; then
    err PIN0 "$rel: $(printf '%s\n' "$records" | sed -n 's/^#ERR\t//p' | head -1)"
    return
  fi

  while IFS=$'\t' read -r _ job step ref; do
    [ -n "${ref:-}" ] || continue

    # This repository's own tree, at this repository's own commit.
    case "$ref" in
      ./*|.\\*) continue ;;
    esac

    if [ "${ref#docker://}" != "$ref" ]; then
      # PIN3 — a container image by tag is a moving target in exactly the same
      # way, and it runs as the step.
      if [ "${ref#*@sha256:}" = "$ref" ]; then
        err PIN3 "$rel: job '$job' step $step uses '$ref' — a docker image by tag; pin it by @sha256: digest"
      fi
      continue
    fi

    owner="${ref%%/*}"
    if [ "${#allow[@]}" -gt 0 ]; then
      local a skip=0
      for a in "${allow[@]}"; do
        [ "$a" = "$owner" ] && skip=1
      done
      [ "$skip" -eq 1 ] && continue
    fi

    path="${ref%@*}"
    version="${ref##*@}"
    if [ "$version" = "$ref" ]; then
      err PIN1 "$rel: job '$job' step $step uses '$ref' with no ref at all — GitHub resolves it against the default branch"
      continue
    fi

    if ! printf '%s' "$version" | grep -qE "$SHA_RE"; then
      err PIN1 "$rel: job '$job' step $step uses '$path@$version' — a tag or branch, not a commit; pin to a 40-character SHA"
      continue
    fi

    # PIN2 — the readable half, asserted on the raw line because a comment is
    # not part of the loaded document.
    #
    # It is asserted on EVERY raw line naming this reference, and that plural is
    # the whole correctness of it. An earlier revision asked whether the SHA
    # appeared anywhere in the file beside a `#`, which is a file-wide question
    # answered by any ONE commented occurrence — so a second `uses:` on the same
    # SHA with no comment passed by standing next to the first. `actions/checkout`
    # appears three or four times in a typical workflow here, so that was not a
    # corner case, it was the common one.
    local ref_re n_uses n_commented
    ref_re="$(re_quote "$path@$version")"
    n_uses="$(grep -cE "uses:[[:space:]]*['\"]?${ref_re}['\"]?([[:space:]]|\$)" "$file")"
    n_commented="$(grep -cE "uses:[[:space:]]*['\"]?${ref_re}['\"]?[[:space:]]*#" "$file")"
    if [ "$n_uses" -gt "$n_commented" ]; then
      err PIN2 "$rel: job '$job' step $step pins '$path' to $version with no version comment on $((n_uses - n_commented)) of $n_uses reference(s) — write '$path@$version # <tag>' on each so the bump is reviewable"
    fi
  done <<EOF
$(printf '%s\n' "$records" | grep '^#USES	')
EOF
}

# See the same directive in `check-runner-policy.sh`: the fixture runner scores
# a planted failure inside `$( )` with its own `fail=0`, so the subshell is the
# isolation rather than an accident.
# shellcheck disable=SC2030
selftest() {
  local tmp status=0
  tmp="$(mktemp -d)"

  expect() {
    local name="$1" want="$2" body="$3"
    shift 3
    local got out_text
    printf '%s\n' "$body" > "$tmp/wf.yml"
    out_text="$(fail=0; check_file "$tmp/wf.yml" "$@" 2>&1)"
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

  expect "pinned by sha with a version comment" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2'

  expect "a mutable tag" "PIN1" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4'

  expect "a branch is no better than a tag" "PIN1" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: some/action@main'

  expect "no ref at all" "PIN1" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: some/action'

  # An abbreviated SHA looks pinned and is not: GitHub resolves it against
  # whatever the repository holds at resolution time.
  expect "an abbreviated sha is not a pin" "PIN1" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd719'

  expect "sha without the readable half" "PIN2" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683'

  # An UPPERCASE pin is still a commit. Rejecting it would be this gate
  # enforcing a house style under a security check's name.
  expect "an uppercase sha is still a pin" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11BD71901BBE5B1630CEEA73D27597364C9AF683 # v4.2.2'

  # The regression PIN2 was written to have and did not: one commented
  # occurrence answering for an uncommented one on the same SHA. Two checkouts
  # in a workflow is the ordinary case, not a contrived one.
  expect "a repeated sha needs its comment on every line" "PIN2" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683'

  expect "a local action needs no pin" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup'

  # The wrapper is immutable; what the wrapper reaches for is not. This runs on
  # the CALLING job's runner with the calling job's token, so exempting it
  # because the path began `./` was exempting the wrong thing.
  expect "a composite action's own dependency is pinned like any other" "PIN1" \
'name: setup
runs:
  using: composite
  steps:
    - uses: third/party@main
      shell: bash'

  expect "a composite action pinned properly is clean" "" \
'name: setup
runs:
  using: composite
  steps:
    - uses: third/party@11bd71901bbe5b1630ceea73d27597364c9af683 # v1.2.3
      shell: bash'

  expect "a reusable workflow on a branch" "PIN1" \
'on: [push]
jobs:
  call:
    uses: owner/repo/.github/workflows/ci.yml@main'

  expect "an allowed owner is exempt" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4' actions

  expect "the allowance is per owner, not global" "PIN1" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: third/party@v1' actions

  expect "docker image by tag" "PIN3" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: docker://alpine:3.20'

  expect "docker image by digest" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: docker://alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000'

  # The reason this gate parses. A `uses:` inside a shell heredoc is not a
  # reference GitHub resolves, and failing a repository for it is how a gate
  # gets deleted rather than fixed.
  expect "a uses: inside a run: block is not a reference" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "uses: actions/checkout@v4"'

  expect "unparseable document" "PIN0" \
'jobs: [ unterminated'

  rm -rf "$tmp"
  return "$status"
}

# SC2031: `fail` is read after the self-test's subshells wrote their own copies.
# Intended — a fixture failure must not reach this exit status, and on the real
# path `check_file` runs in this shell.
# shellcheck disable=SC2031
main() {
  local run_selftest=0 arg
  local -a files=() allow=()

  for arg in "$@"; do
    case "$arg" in
      --selftest) run_selftest=1 ;;
      --allow=*)  allow+=("${arg#--allow=}") ;;
      -*)         echo "::error::[PIN0] unknown option: $arg"; return 1 ;;
      *)          files+=("$arg") ;;
    esac
  done

  if ! ensure_yaml; then
    echo "::error::[PIN0] no Python with PyYAML available; this gate cannot read a workflow"
    return 1
  fi

  if [ "$run_selftest" -eq 1 ]; then
    selftest
    return
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    # Composite action manifests are discovered alongside workflows, at any
    # depth under `.github/actions`, because a local `uses:` is exempted from
    # pinning and its own dependencies are not.
    while IFS= read -r arg; do
      [ -n "$arg" ] || continue
      files+=("$arg")
    done <<EOF
$( { find "$REPO_ROOT/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
     find "$REPO_ROOT/.github/actions" -type f \( -name 'action.yml' -o -name 'action.yaml' \) 2>/dev/null
   } | sort)
EOF
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    echo "::error::[PIN0] no workflow files found under .github/workflows — nothing was checked"
    return 1
  fi

  local f
  for f in "${files[@]}"; do
    if [ "${#allow[@]}" -gt 0 ]; then
      check_file "$f" "${allow[@]}"
    else
      check_file "$f"
    fi
  done

  if [ "$fail" -eq 0 ]; then
    echo "action pins clean: ${#files[@]} workflow file(s)"
  fi
  return "$fail"
}

main "$@"
