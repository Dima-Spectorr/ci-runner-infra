#!/usr/bin/env bash
# ci-runner-infra — which CI lane a pull request belongs in, as a PURE function.
#
# WHY THIS FILE EXISTS
#
# Every repository in the fleet answers "how much CI does this diff deserve?"
# and every one of them answers it differently. The audit in
# docs/ci-optimization-catalog.md found the same rule re-derived in four repos
# with four different path lists, and two of them evaluate it INSIDE a
# `runs-on: [self-hosted, ...]` job — so a documentation-only pull request
# claims a pool slot in order to decide it has nothing to do. In Apigee-Portal
# that is thirteen slots to run nothing.
#
# The rule belongs in one place, testable, so a wrong verdict is caught here
# rather than by a pull request that skipped the check that would have caught it.
#
# THE INVARIANT THAT MATTERS
#
# The dangerous direction is asymmetric. Running too much CI costs runner
# seconds. Running too little merges untested code. So:
#
#   * `none` requires EVERY path to be provably non-code. One code file in a
#     hundred documentation files is enough to leave the lane.
#   * anything unrecognised is `partial`, never `none`. A new file type added
#     next year gets tested by default.
#   * an empty diff is `full`, not `none` — an empty list means the caller
#     failed to compute the diff, and a failed diff must never read as "nothing
#     changed".
#
# Tenancy-agnostic — no customer literals, no repository knowledge. Consumers
# adopt it through the contract in docs/ci-lane-model.md.

# lane_decision  — reads newline-separated repository-relative paths on stdin
#                  (the format `git diff --name-only` emits), echoes
#                  "<lane>:<reason>" and exits 0.
#
# Lanes:
#   full    : everything runs. The diff can invalidate any check — build
#             toolchain, dependency graph, CI definition itself, infrastructure,
#             or the database schema.
#   partial : the affected-area jobs run, the rest are skipped by the caller's
#             job-level `if:`. This is the normal lane for ordinary code.
#   none    : no self-hosted job runs at all. The caller still reports its
#             aggregate check so the merge queue is satisfied.
#
# The verdict is the OUTPUT, not the exit status, so a `set -e` caller cannot be
# tripped by a lane it did not expect.
lane_decision() {
  local path
  local saw_any=0
  local saw_full=0
  local saw_partial=0
  local full_path=""

  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    saw_any=1

    case "$(classify_path "$path")" in
      full)
        # Keep reading rather than short-circuiting: the reason line names the
        # FIRST full-lane path so a surprising verdict can be explained from the
        # job log alone, and draining stdin avoids a SIGPIPE in the caller's
        # `git diff`.
        if [ "$saw_full" -eq 0 ]; then
          saw_full=1
          full_path="$path"
        fi
        ;;
      partial) saw_partial=1 ;;
      none) ;;
    esac
  done

  # An empty diff is a FAILED diff until proven otherwise. The caller that
  # computed zero changed paths for a pull request either lost its merge base or
  # was handed the wrong ref; either way "nothing changed" is the one answer
  # that must not be reachable by accident.
  if [ "$saw_any" -eq 0 ]; then
    echo "full:empty-diff — no paths on stdin, cannot prove the lane"
    return 0
  fi

  if [ "$saw_full" -eq 1 ]; then
    echo "full:full-lane-path=$full_path"
    return 0
  fi

  if [ "$saw_partial" -eq 1 ]; then
    echo "partial:code-paths-changed"
    return 0
  fi

  echo "none:non-code-only"
  return 0
}

# classify_path <path> — echoes full | partial | none for ONE path.
#
# Order is load-bearing and is documentation-first on purpose. Four repositories
# keep a `.github/workflows/AGENTS.md`; a workflow-directory rule evaluated
# first would put a comment edit in that file into the full lane, which is the
# opposite of the point.
classify_path() {
  local p="$1"
  local lower="${p,,}"

  # ---------------------------------------------------------------------------
  # 1. Provably non-code. Nothing here is read by a build, a test, or a deploy.
  # ---------------------------------------------------------------------------
  case "$lower" in
    *.md | *.mdx | *.txt | *.rst | *.adoc) echo none; return 0 ;;
    *.png | *.jpg | *.jpeg | *.gif | *.svg | *.webp | *.ico | *.pdf) echo none; return 0 ;;
    docs/* | */docs/*) echo none; return 0 ;;
    .claude/*) echo none; return 0 ;;
    .github/issue_template/* | .github/pull_request_template*) echo none; return 0 ;;
    license | license.* | notice | authors | codeowners | .github/codeowners) echo none; return 0 ;;
  esac

  # ---------------------------------------------------------------------------
  # 2. Full lane. Each entry can invalidate a check that reads none of the files
  #    it changed — which is exactly the class an affected-only filter misses.
  # ---------------------------------------------------------------------------
  case "$lower" in
    # The CI definition itself. A workflow edit changes what "green" means, so
    # it cannot be validated by a subset of the checks it defines.
    .github/workflows/* | .github/actions/* | .mergify.yml | .mergify.yaml) echo full; return 0 ;;

    # Dependency graph. A lockfile bump moves transitive code that every job
    # links against while touching no source file any filter would match.
    */package-lock.json | package-lock.json | */yarn.lock | yarn.lock) echo full; return 0 ;;
    */pnpm-lock.yaml | pnpm-lock.yaml | */go.sum | go.sum | */go.mod | go.mod) echo full; return 0 ;;
    */cargo.lock | cargo.lock | */poetry.lock | poetry.lock) echo full; return 0 ;;
    */requirements*.txt | requirements*.txt) echo full; return 0 ;;
    */pom.xml | pom.xml | */build.gradle* | build.gradle*) echo full; return 0 ;;

    # Build toolchain and packaging. Apigee-Portal's "Validator image boots and
    # serves" exists because a bundler flag, a target bump or a minifier change
    # is invisible to every source-reading gate.
    dockerfile* | */dockerfile* | docker-compose*) echo full; return 0 ;;
    cloudbuild*.yaml | cloudbuild*.yml | */cloudbuild*.yaml) echo full; return 0 ;;
    makefile | */makefile | package.json | */package.json) echo full; return 0 ;;
    turbo.json | nx.json | tsconfig*.json | */tsconfig*.json) echo full; return 0 ;;
    .nvmrc | .node-version | .tool-versions | .python-version) echo full; return 0 ;;

    # Infrastructure. A pool, a network or an IAM change alters the environment
    # every job runs in.
    *.tf | *.tfvars | infra/* | */infra/* | terraform/* | */terraform/*) echo full; return 0 ;;
    *.pkr.hcl | packer/*) echo full; return 0 ;;

    # Schema. A migration is evaluated against the whole database, not against
    # the services whose files changed alongside it.
    */migrations/* | migrations/* | */migration/* | db/*) echo full; return 0 ;;
    *.sql) echo full; return 0 ;;
  esac

  # ---------------------------------------------------------------------------
  # 3. Everything else is ordinary code — and so is everything UNRECOGNISED.
  #    A file type this rule has never seen gets tested, not skipped.
  # ---------------------------------------------------------------------------
  echo partial
}
