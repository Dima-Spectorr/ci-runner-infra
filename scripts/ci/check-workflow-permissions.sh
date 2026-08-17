#!/usr/bin/env bash
# =============================================================================
# check-workflow-permissions.sh — what a job may do to the repository is stated,
# not inherited
#
# USAGE
#   bash scripts/ci/check-workflow-permissions.sh [--selftest]
#                                       [--allow-workflow-write=<scope>]...
#                                       [--allow-inherit] [<file>...]
#
# PURPOSE
#   Every job says what it may do to the repository, and says it at the job that
#   needs it.
#
#     PERM1  a job's effective permission set is STATED — not left to the
#            repository default
#     PERM2  a write scope is granted at the job that needs it, not to every job
#            in the file; `write-all` is never that
#     PERM3  a remote reusable workflow is not handed `secrets: inherit`
#     PERM4  a set this gate cannot resolve is REPORTED, not passed
#
# WHY THIS FLEET AND NOT SOME OTHER
#   `GITHUB_TOKEN` is minted per job and mounted into it. Omit `permissions:`
#   and the job does not get "nothing" — it gets whatever the REPOSITORY default
#   is, a setting that lives in a web console, that no reviewer of the workflow
#   can see, and that is `read-write` for every repository created before
#   GitHub changed the default. Nothing in the pull request shows it.
#
#   On this fleet that lands somewhere worse than usual. A job runs on a WARM
#   host, beside other jobs' caches and checked-out trees, and its token is
#   readable by every step in it — including the install scripts of every
#   transitive dependency it downloads. `check-action-pins.sh` closes the
#   arriving half of that (the code is pinned); this closes the other half: what
#   that code can DO once it runs. A pinned action with a write token is still a
#   write token.
#
# WHY "STATED" AND NOT "SMALL" (PERM1)
#   The rule is not that a job holds few permissions — plenty of jobs genuinely
#   need `contents: write`. The rule is that the answer is IN THE FILE. An
#   unstated set is not a small set and is not a large one; it is an unknown
#   one, and it changes when somebody flips a repository setting for an
#   unrelated reason. A gate that guessed the default would be asserting
#   something it cannot read, so it asks for the declaration instead.
#
#   A workflow-level `permissions:` answers this for every job in the file, so
#   the common shape — one `permissions: {contents: read}` at the top — passes
#   with one line.
#
# WHY WORKFLOW-LEVEL WRITE IS THE FINDING, AND JOB-LEVEL WRITE IS NOT (PERM2)
#   This is the whole low-noise design. Refusing `contents: write` outright
#   would fail every release workflow in the fleet, and a gate that fails
#   correct code gets an `|| true` on it within the month. What is actually
#   wrong is a write granted at the TOP of a file that also contains a lint job,
#   a docs job and a matrix of test shards: they all inherit it, none of them
#   needs it, and the blast radius of any one of them is the write.
#
#   So the finding is placement, and the fix is mechanical — move the scope down
#   to the job that uses it. `write-all` is a finding wherever it appears,
#   because it is every scope at once and no job needs every scope.
#
#   A ONE-JOB file is exempt from the placement rule: there, the top of the file
#   and the job that needs it are the same scope, and there is nothing to move.
#   The rule starts applying the day a second job is added — which is the day
#   the grant starts reaching something that does not need it.
#
#   `--allow-workflow-write=<scope>` exists for the file that is genuinely one
#   job's worth of work spread over two jobs. Like `check-action-pins.sh`'s
#   `--allow=<owner>`, it is a visible argument in the consuming workflow rather
#   than a silent default here.
#
# WHY `secrets: inherit` IS ITS OWN RULE (PERM3)
#   `permissions:` governs the token. It says nothing about the repository's
#   OTHER secrets, and `secrets: inherit` on a call to `owner/repo/.github/
#   workflows/x.yml@ref` hands every one of them to a workflow this repository
#   does not define and whose diff nobody here reviews. The token can be
#   narrowed to nothing and that call still passes the signing key.
#
#   A LOCAL callee (`./.github/workflows/x.yml`) is this repository's own tree
#   at this repository's own commit — reviewed in the same pull request — so it
#   is not a finding, the same exemption `check-action-pins.sh` gives `./…`.
#
# WHY AN EXPRESSION IS UNDECIDED (PERM4)
#   `permissions: ${{ fromJSON(inputs.perms) }}` is a value this gate cannot
#   resolve, and calling it stated or unstated are both answers to a question
#   that was never asked. Reported as UNDECIDED rather than passed — the rule
#   `check-runner-policy.sh` follows for a dynamic `runs-on` (RUNNER5) and
#   `check-action-pins.sh` for an unresolvable image (PIN4).
#
# WHAT THIS GATE DOES NOT DECIDE
#   Whether a job that legitimately holds `contents: write` deserves it. That is
#   a review question about intent, and a gate that guessed would be wrong in
#   the direction that matters. It decides placement and disclosure only.
#
#   It also does not read a REMOTE callee's own `permissions:`. GitHub will not
#   let a callee widen what the caller granted, so the caller's declaration is
#   the ceiling and the ceiling is what is checked here.
#
# EXIT CODES
#   0 — clean
#   1 — a finding
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0
err() { local id="$1"; shift; echo "::error::[$id] $*"; fail=1; }

# Scopes a consumer has declared it accepts at workflow level. `|`-delimited so
# a plain substring test answers membership without an array in a function that
# is also called from the fixtures.
ALLOW_WORKFLOW_WRITE="|"
# Declared acceptance of `secrets: inherit` to a remote callee — see PERM3.
ALLOW_INHERIT=0

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

# Emits one record per job, plus one for the workflow itself:
#
#   #ERR\t<message>
#   #TOP\t<state>\t<writes>            state: none|all|map|expr
#   #JOB\t<job>\t<state>\t<writes>\t<callee>\t<secrets>
#
# `writes` is a comma-separated list of scopes set to `write`. `callee` is the
# job-level `uses:` if there is one, and `secrets` is `inherit`, `map` or `-`.
#
# Read from the loaded document rather than by grepping `permissions:`, because
# the word appears in `run:` scripts, in `with:` values and in comments — and a
# gate that fails a repository for a string in a shell script is a gate that
# gets deleted rather than fixed.
read_perms() {
  "${PY_BIN:-python3}" - "$1" <<'PY'
import sys, yaml

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(newline="\n")


def out(*fields):
    print("\t".join(str(f).replace("\t", " ").replace("\n", " ") for f in fields))


def classify(value, present):
    """(state, comma-joined write scopes) for one `permissions:` value.

    `present` distinguishes an absent key from `permissions: {}`, which is the
    explicit empty set and the strongest possible declaration — the two must not
    collapse into the same answer.
    """
    if not present:
        return "none", ""
    if isinstance(value, str):
        text = value.strip()
        if "${{" in text:
            return "expr", ""
        if text == "write-all":
            return "all", ""
        # `read-all` and the empty string are both stated and hold no write.
        return "map", ""
    if isinstance(value, dict):
        writes = []
        for scope, level in value.items():
            if isinstance(level, str) and "${{" in level:
                return "expr", ""
            if isinstance(level, str) and level.strip() == "write":
                writes.append(str(scope))
        return "map", ",".join(sorted(writes))
    if value is None:
        # `permissions:` with nothing under it parses as None. That is not the
        # empty set — it is a key somebody started writing, and GitHub treats it
        # as no permissions. Stated, and holding nothing.
        return "map", ""
    return "expr", ""


try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except Exception as exc:  # noqa: BLE001
    out("#ERR", " ".join(str(exc).split())[:400])
    sys.exit(0)

if not isinstance(doc, dict):
    out("#ERR", "workflow is not a mapping")
    sys.exit(0)

top_state, top_writes = classify(doc.get("permissions"), "permissions" in doc)
out("#TOP", top_state, top_writes)

jobs = doc.get("jobs")
if not isinstance(jobs, dict):
    # No `jobs:` — an action manifest or a fragment. `permissions:` is not a key
    # either of those carries, so there is nothing here to decide.
    sys.exit(0)

for job_id, job in jobs.items():
    if not isinstance(job, dict):
        continue
    state, writes = classify(job.get("permissions"), "permissions" in job)

    callee = job["uses"].strip() if isinstance(job.get("uses"), str) else "-"

    secrets = "-"
    if "secrets" in job:
        value = job["secrets"]
        if isinstance(value, str) and value.strip() == "inherit":
            secrets = "inherit"
        else:
            secrets = "map"

    # No field may be empty. `read` with `IFS=$'\t'` still treats a tab as IFS
    # WHITESPACE and collapses a run of them, so one empty column silently
    # shifts every column after it — which is how `secrets` arrives as the
    # callee and a finding disappears. Placeholders keep the record positional.
    out("#JOB", job_id, state, writes or "-", callee or "-", secrets)
PY
}

check_file() {
  local file="$1" rel records status
  rel="${file#"$REPO_ROOT"/}"

  # The parser's exit status, not just its output. Killed by the OOM killer or
  # dying on an interpreter-level fault it emits no `#ERR` and no records — and
  # an empty record set is indistinguishable from a file with no jobs. That is
  # the vacuous pass this gate's whole design is arranged against, so it is
  # caught here rather than trusted.
  records="$(read_perms "$file")"
  status=$?
  if [ "$status" -ne 0 ]; then
    err PERM0 "$rel: the YAML reader exited $status without a verdict — treating as unreadable rather than clean"
    return
  fi

  if printf '%s\n' "$records" | grep -q '^#ERR	'; then
    err PERM0 "$rel: $(printf '%s\n' "$records" | sed -n 's/^#ERR\t//p' | head -1)"
    return
  fi

  # A file the parser read but emitted no `#TOP` for never reached the emitter.
  if ! printf '%s\n' "$records" | grep -q '^#TOP	'; then
    err PERM0 "$rel: the YAML reader produced no verdict for the workflow itself"
    return
  fi

  local top_state top_writes
  top_state="$(printf '%s\n' "$records" | sed -n 's/^#TOP\t\([a-z]*\)\t.*/\1/p' | head -1)"
  top_writes="$(printf '%s\n' "$records" | sed -n 's/^#TOP\t[a-z]*\t//p' | head -1)"

  if [ "$top_state" = "expr" ]; then
    err PERM4 "$rel: workflow-level permissions are chosen by an expression — this gate cannot resolve it, so it is undecided rather than clean"
  fi

  if [ "$top_state" = "all" ]; then
    err PERM2 "$rel: workflow-level 'permissions: write-all' — every job in this file gets every scope, including the ones that only read"
  fi

  local job_count
  job_count="$(printf '%s\n' "$records" | grep -c '^#JOB	')"

  # A write at the top of the file reaches every job in it. The fix is to move
  # the scope onto the job that uses it, which is why the message names them.
  #
  # In a ONE-JOB file "the top of the file" and "the job that needs it" are the
  # same scope, and firing there would fail correct code — the fastest way to
  # get a gate `|| true`-d out of a workflow. It fires on the day a second job
  # is added, which is the day the grant starts reaching something that does not
  # need it, and the day the fix is a two-line move.
  # Split on the comma with globbing off. The scope names come from the
  # document's own keys, and an unquoted split would let a key of `*` expand
  # against the working directory.
  local scope
  local -a top_write_scopes=()
  if [ -n "$top_writes" ]; then
    local saved_glob=0
    case "$-" in *f*) saved_glob=1 ;; esac
    set -f
    IFS=',' read -r -a top_write_scopes <<< "$top_writes"
    [ "$saved_glob" -eq 1 ] || set +f
  fi

  if [ "${#top_write_scopes[@]}" -gt 0 ] && [ "$job_count" -gt 1 ]; then
    for scope in "${top_write_scopes[@]}"; do
      case "$ALLOW_WORKFLOW_WRITE" in
        *"|$scope|"*) continue ;;
      esac
      err PERM2 "$rel: workflow-level '$scope: write' is granted to every job in this file — move it to the job that needs it, or declare it with --allow-workflow-write=$scope"
    done
  fi

  # SC2034: `writes` is read and never used. It is a POSITION, not a value —
  # the record is fixed-width and dropping the field would shift `callee` and
  # `secrets` into each other, which is the bug the `-` placeholders exist to
  # prevent. Per-job writes are PERM2's business only at workflow level.
  local _ job state writes callee secrets
  # shellcheck disable=SC2034
  while IFS=$'\t' read -r _ job state writes callee secrets; do
    [ -n "${job:-}" ] || continue

    if [ "$state" = "expr" ]; then
      err PERM4 "$rel: job '$job' chooses its permissions by an expression — this gate cannot resolve it, so it is undecided rather than clean"
    fi

    # PERM1 — nothing stated here and nothing stated above it, so the job runs
    # with the repository default: a value in a web console, invisible to every
    # reviewer of this file, and `read-write` for any repository created before
    # GitHub changed it.
    if [ "$state" = "none" ] && [ "$top_state" = "none" ]; then
      err PERM1 "$rel: job '$job' states no permissions and neither does the workflow — it inherits the repository default, which is not visible in this file"
    fi

    if [ "$state" = "all" ]; then
      err PERM2 "$rel: job '$job' takes 'permissions: write-all' — that is every scope at once, and no job needs every scope"
    fi

    # PERM3 — the token is not the only thing a call hands over. A remote callee
    # is code this repository does not define; `inherit` gives it every secret
    # the repository holds, whatever the token was narrowed to.
    if [ "$secrets" = "inherit" ] && [ "$ALLOW_INHERIT" -eq 0 ]; then
      case "$callee" in
        -|./*|.\\*) ;;
        *) err PERM3 "$rel: job '$job' passes 'secrets: inherit' to '$callee', a workflow this repository does not define — name the secrets it needs, or declare it with --allow-inherit" ;;
      esac
    fi
  done <<EOF
$(printf '%s\n' "$records" | grep '^#JOB	')
EOF
}

# SC2031: `fail` is read after the self-test's subshells wrote their own copies.
# Intended — a fixture failure must not reach this exit status, and on the real
# path `check_file` runs in this shell.
#
# SC2016: every fixture below is single-quoted on purpose. A `${{ … }}` in one
# is the literal text the gate must classify as an expression; expanding it here
# would delete the thing under test.
# shellcheck disable=SC2030,SC2031,SC2016
selftest() {
  local tmp status=0
  tmp="$(mktemp -d)"

  expect() {
    local name="$1" want="$2" body="$3"
    local got out_text
    printf '%s\n' "$body" > "$tmp/wf.yml"
    out_text="$(fail=0; check_file "$tmp/wf.yml" 2>&1)"
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

  expect "one workflow-level read answers for every job" "" \
'on: [push]
permissions:
  contents: read
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  expect "nothing stated anywhere" "PERM1" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  # The declaration may be at either level; a job that states its own set does
  # not need the workflow to have stated one.
  expect "a job states its own set" "" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - run: echo hi'

  # Every job is reported, not just the first one that is wrong — a gate that
  # stops at the first finding turns one fix into as many pull requests as the
  # file has jobs.
  expect "one stated job does not answer for its unstated sibling" "PERM1" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - run: echo hi
  publish:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  # `permissions: {}` is the strongest declaration there is. Collapsing it into
  # "absent" would fail the safest workflow in the fleet.
  expect "the explicit empty set is stated" "" \
'on: [push]
permissions: {}
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  # `permissions:` with nothing under it loads as None. Stated, holding nothing.
  expect "a bare permissions key is stated and holds nothing" "" \
'on: [push]
permissions:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  expect "read-all is stated and holds no write" "" \
'on: [push]
permissions: read-all
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  expect "write-all at the top" "PERM2" \
'on: [push]
permissions: write-all
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  expect "write-all on one job" "PERM2" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions: write-all
    steps:
      - run: echo hi'

  # The rule that keeps this gate quiet: a write where it is used is correct,
  # and refusing it would fail every release workflow in the fleet.
  expect "a write on the job that needs it" "" \
'on: [push]
permissions:
  contents: read
jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - run: echo hi'

  # The same scope one level up reaches the lint job too.
  expect "the same write at the top of the file" "PERM2" \
'on: [push]
permissions:
  contents: write
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  # One job: the top of the file IS the job that needs it, so there is nothing
  # to move and nothing to report. Both of this repository's own findings on the
  # first run were this shape.
  expect "a workflow-level write in a one-job file" "" \
'on: [push]
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  # ...but write-all is a finding at any job count. It is every scope at once,
  # and "the job needs it" is never true of every scope.
  expect "write-all in a one-job file" "PERM2" \
'on: [push]
permissions: write-all
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  ALLOW_WORKFLOW_WRITE="|contents|"
  expect "a declared workflow-level write is accepted" "" \
'on: [push]
permissions:
  contents: write
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  # The declaration is per scope. Accepting `contents` must not quietly accept
  # the OIDC token beside it, which is the one that exchanges for cloud
  # credentials on this fleet.
  expect "a declaration covers only the scope it names" "PERM2" \
'on: [push]
permissions:
  contents: write
  id-token: write
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'
  ALLOW_WORKFLOW_WRITE="|"

  expect "secrets: inherit to a remote callee" "PERM3" \
'on: [push]
permissions:
  contents: read
jobs:
  call:
    uses: other/repo/.github/workflows/build.yml@11bd71901bbe5b1630ceea73d27597364c9af683
    secrets: inherit'

  # A local callee is this repository at this commit, reviewed in the same pull
  # request — the exemption `check-action-pins.sh` gives `./…`.
  expect "secrets: inherit to a local callee" "" \
'on: [push]
permissions:
  contents: read
jobs:
  call:
    uses: ./.github/workflows/build.yml
    secrets: inherit'

  # Naming the secrets is the fix PERM3 asks for, so it has to pass.
  expect "named secrets to a remote callee" "" \
'on: [push]
permissions:
  contents: read
jobs:
  call:
    uses: other/repo/.github/workflows/build.yml@11bd71901bbe5b1630ceea73d27597364c9af683
    secrets:
      token: ${{ secrets.NARROW }}'

  ALLOW_INHERIT=1
  expect "a declared inherit is accepted" "" \
'on: [push]
permissions:
  contents: read
jobs:
  call:
    uses: other/repo/.github/workflows/build.yml@11bd71901bbe5b1630ceea73d27597364c9af683
    secrets: inherit'
  ALLOW_INHERIT=0

  expect "a set chosen by an expression is undecided" "PERM4" \
'on: [push]
permissions: ${{ fromJSON(inputs.perms) }}
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

  expect "a scope level chosen by an expression is undecided" "PERM4" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: ${{ inputs.level }}
    steps:
      - run: echo hi'

  # The reason this gate parses instead of grepping. `permissions:` in a shell
  # heredoc is not a declaration GitHub reads, and failing a repository for it
  # is how a gate gets deleted rather than fixed.
  expect "the word inside a run: block is not a declaration" "PERM1" \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "permissions: write-all"'

  expect "unparseable document" "PERM0" \
'jobs: [ unterminated'

  # A document that loads but is not a mapping — `#TOP` is emitted by the same
  # path that reports it, so this proves the reader is heard rather than assumed.
  expect "a document that is not a mapping" "PERM0" \
'- just
- a
- list'

  rm -rf "$tmp"
  return "$status"
}

# SC2031: as above — the self-test's subshells write their own `fail`.
# shellcheck disable=SC2031
main() {
  local run_selftest=0 arg
  local -a files=()

  for arg in "$@"; do
    case "$arg" in
      --selftest) run_selftest=1 ;;
      --allow-workflow-write=*)
        ALLOW_WORKFLOW_WRITE="$ALLOW_WORKFLOW_WRITE${arg#--allow-workflow-write=}|" ;;
      --allow-inherit) ALLOW_INHERIT=1 ;;
      -*) echo "::error::[PERM0] unknown option: $arg"; return 1 ;;
      *)  files+=("$arg") ;;
    esac
  done

  if ! ensure_yaml; then
    echo "::error::[PERM0] no Python with PyYAML available; this gate cannot read a workflow"
    return 1
  fi

  if [ "$run_selftest" -eq 1 ]; then
    selftest
    return
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    while IFS= read -r arg; do
      [ -n "$arg" ] || continue
      files+=("$arg")
    done <<EOF
$(find "$REPO_ROOT/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
EOF
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    echo "::error::[PERM0] no workflow files found under .github/workflows — nothing was checked"
    return 1
  fi

  local f
  for f in "${files[@]}"; do
    check_file "$f"
  done

  if [ "$fail" -eq 0 ]; then
    echo "workflow permissions clean: ${#files[@]} workflow file(s)"
  fi
  return "$fail"
}

main "$@"
