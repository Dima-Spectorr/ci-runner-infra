#!/usr/bin/env bash
# Self-test for the CI lane rule.
#
# This exists because the rule's failure modes are asymmetric and one of them is
# silent. A lane that is too WIDE costs runner seconds and announces itself in
# the bill. A lane that is too NARROW merges code that no job read, and looks
# green while doing it. Every case below asserts the narrow direction as hard as
# the wide one.
#
# Cases are drawn from paths that actually exist in the fleet, not synthetic
# inputs — `.github/workflows/AGENTS.md` in four repositories, DataRetrival's
# migration ledger, Apigee-Portal's mixed documentation-plus-code pull requests.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/lane-decision.sh"

PASS=0
FAIL=0

# expect <expected-lane> <description> <path...>
expect() {
  local want="$1" desc="$2"
  shift 2
  local got
  got=$(printf '%s\n' "$@" | lane_decision)
  if [[ "$got" == "$want:"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  paths: %s\n  want: %s:*\n  got:  %s\n' "$desc" "$*" "$want" "$got"
  fi
}

# --- the no-runner lane, which is the whole point -----------------------------
expect none "a README edit runs no self-hosted job" \
  README.md
expect none "a documentation tree edit is non-code" \
  docs/architecture.md docs/img/flow.png
expect none "agent instructions are not build inputs" \
  .claude/rules/infra-genericity.md .claude/settings.json
expect none "issue and pull-request templates are not build inputs" \
  .github/ISSUE_TEMPLATE/bug.md .github/PULL_REQUEST_TEMPLATE.md
expect none "CODEOWNERS routes review, it does not change behaviour" \
  CODEOWNERS

# Documentation-first ordering. Four repositories keep this exact file; a
# workflow-directory rule evaluated before the documentation rule would put a
# comment edit into the full lane and undo the saving on the most-edited doc in
# the repository.
expect none "a markdown file INSIDE .github/workflows is still documentation" \
  .github/workflows/AGENTS.md

# --- one code file leaves the lane, however much documentation surrounds it ---
expect partial "documentation plus one source file is NOT the no-runner lane" \
  docs/a.md docs/b.md docs/c.md src/server.ts
expect full "documentation plus a lockfile is the full lane" \
  README.md package-lock.json

# --- the full lane: diffs that invalidate checks reading none of their files --
expect full "a workflow edit changes what green means" \
  .github/workflows/ci.yml
expect full "a merge-queue config edit changes what is required to merge" \
  .mergify.yml
expect full "a lockfile moves transitive code no source filter matches" \
  apps/web/package-lock.json
expect full "go.sum is the same hazard as package-lock.json" \
  go.sum
expect full "a Dockerfile is the build toolchain, invisible to source gates" \
  apps/api/Dockerfile
expect full "a bundler or compiler option change is invisible to source gates" \
  tsconfig.build.json
expect full "package.json carries scripts and dependency ranges" \
  package.json
expect full "infrastructure changes the environment every job runs in" \
  infra/terraform/pool.tf
expect full "the golden image definition changes every job's toolchain" \
  packer/ci-host-image.pkr.hcl
expect full "a migration is evaluated against the whole schema" \
  services/api/migrations/20260814_add_index.sql
expect full "a pinned toolchain version applies to every job" \
  .nvmrc

# --- build inputs wearing a documentation costume ------------------------------
# Each of these matches a NON-CODE rule textually. If the ordering in
# classify_path ever regresses, they take the lane that runs no CI at all, and
# nothing else in this suite notices.
expect full "requirements.txt is a dependency graph, not a text file"   requirements.txt
expect full "a nested dev requirements file is the same hazard"   services/api/requirements-dev.txt
expect full "a package.json under docs/ is still a dependency manifest"   docs/package.json
expect full "a Sphinx conf.py executes, wherever it lives"   docs/conf.py
expect full "pyproject.toml carries dependencies and build backend"   pyproject.toml
expect full "a nested Cloud Build config uses the .yml spelling too"   services/api/cloudbuild.yml
expect full "a nested compose file changes the build outside any source filter"   services/api/docker-compose.yml

# Images are only provably non-code inside a documentation tree. Elsewhere they
# are bundled production inputs or visual-regression expectations.
expect none "an image in the documentation tree is non-code"   docs/img/flow.svg
expect partial "an image under src/ is a bundled production input"   src/assets/logo.svg
expect partial "a test fixture image is an assertion, not decoration"   tests/visual/__snapshots__/header.png

# --- fail-safe: unrecognised means tested, never skipped ----------------------
expect partial "an unrecognised extension is tested, not skipped" \
  src/thing.zig
expect partial "a bare extensionless script is tested, not skipped" \
  scripts/deploy
expect partial "a dotfile the rule has never seen is tested, not skipped" \
  .prettierrc

# --- fail-safe: an empty diff is a FAILED diff --------------------------------
# The caller lost its merge base or was handed the wrong ref. "Nothing changed"
# is the one verdict that must not be reachable by accident, because it is
# indistinguishable from a pull request that merges with no check having run.
expect full "no paths at all is the full lane, never the no-runner lane" \
  ""

# --- the verdict must explain itself from the job log alone -------------------
# A lane that is wider than expected is investigated by reading one line of CI
# output. If that line does not name the path responsible, the investigation
# becomes a manual re-classification of the whole diff.
reason=$(printf 'README.md\napps/web/package-lock.json\nsrc/a.ts\n' | lane_decision)
if [[ "$reason" == "full:full-lane-path=apps/web/package-lock.json" ]]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL: the full-lane reason names the path that caused it\n  got: %s\n' "$reason"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
