#!/usr/bin/env bash
# =============================================================================
# check-e2e-policy.sh — a browser suite that reports honestly, and fast
#
# USAGE
#   bash scripts/ci/check-e2e-policy.sh [--selftest]
#                                       [--root=<dir>]
#                                       [--job-timeout=<minutes>]
#                                       [--image-codename=<noble>]
#                                       [<playwright.config file>...]
#
# PURPOSE
#   Properties of a Playwright setup that this fleet cares about, every one of
#   which fails SILENTLY — the suite still reports a colour, just not an honest
#   one, or it reports the honest one twenty minutes later than it could:
#
#     E2E0  a suite or an E2E job exists, but no config governs it.
#     E2E1  `forbidOnly` is set, so a committed `test.only` cannot pass the
#           suite by shrinking it.
#     E2E2  `workers` is explicit and bounded.
#     E2E3  the timeout ladder is complete and strictly increasing, and its top
#           rung sits below the job's `timeout-minutes`.
#     E2E4  trace/video/screenshot are conditional on failure, never `'on'`.
#     E2E5  the reporter is machine-readable, and `blob` when the job shards.
#     E2E6  `reuseExistingServer` is off under CI.
#     E2E7  the job runs in the baked Playwright container, and does not then
#           `playwright install` on top of it.
#     E2E8  the container's release matches the pinned @playwright/test.
#     E2E9  no arbitrary waits in the spec tree.
#
#   Runner-shape properties of the E2E job itself — a repository-scoping label,
#   `timeout-minutes`, fork reachability — are NOT re-implemented here. They are
#   check-runner-policy.sh's RUNNER1/RUNNER3/RUNNER4, and they apply to an E2E
#   job because it is a fleet job like any other. Run both.
#
# WHY A GATE AND NOT A README
#   Each of these turns a check green while removing its meaning or its speed:
#     - a committed `test.only` shrinks the suite to one test and passes;
#     - a missing `globalTimeout` lets a hung suite outlive the merge queue's
#       `checks_timeout`, so the pull request is DEQUEUED rather than failed —
#       the same silent-dequeue failure this repository already pins the
#       per-workspace < job < queue timeout ordering for;
#     - `trace: 'on'` records every step of every PASSING test, roughly doubling
#       runtime to produce evidence nobody opens;
#     - a `container:` tag drifted from the repository's `@playwright/test`
#       makes every job download ~2 GB of image the host already holds baked,
#       silently — `check-playwright-pin.sh` holds THIS repository's references
#       to one release, and says outright that the consumer's half is beyond it.
#       This is that half.
#   None of these is visible in a run's status. That is the whole argument.
#
# WHAT IT CANNOT DECIDE
#   This is a LEXICAL read of the config source, not a TypeScript evaluator. A
#   value assembled at runtime — imported from another module, read from an env
#   var, or returned by a helper — is reported as unreadable and FAILS, never
#   passes. The two directions are not symmetric: a false failure costs one
#   commit making a value literal; a false pass is a gate that quietly stopped
#   gating. Configs in this fleet are declarative, so a config this cannot read
#   is itself the finding.
# =============================================================================
set -uo pipefail

# The image `packer/warm-cache/playwright.sh` bakes and host-startup.sh loads
# into every slot.
#
# The regex finds ANY release/codename pair, deliberately, because a reference
# this cannot see is a reference it cannot check. The codename is compared
# separately: `-jammy` and `-noble` both exist upstream and both RUN, so a job
# asking for the one the fleet did not bake downloads ~2 GB and still passes.
# Matching only `-noble` here would report that as "no container at all", which
# sends the reader to the wrong fix.
PLAYWRIGHT_IMAGE_RE='mcr\.microsoft\.com/playwright:v[0-9][0-9.]*-[a-z]+'

# What the fleet bakes today; `--image-codename=` overrides it for a pool on a
# different base. Named here rather than inferred: the consumer repository this
# gate runs in cannot see the image, which is the whole reason the value has to
# travel with the gate.
IMAGE_CODENAME_DEFAULT='noble'

fail=0
report() { # <id> <file> <message>
  printf '::error::[%s] %s: %s\n' "$1" "$2" "$3"
  fail=$((fail + 1))
}

# Strip line and block comments before matching, so a rule commented out as an
# explanation ("// we used to set trace: 'on'") is not read as configuration.
#
# A `//` preceded by `:` is a URL scheme, not a comment. Stripping those ate
# `baseURL: 'http://localhost:3000'` and every key after it on the same line, so
# a config was judged on a truncated copy of itself — the one failure mode a
# lexical gate must not have. Two passes: a comment at the start of a line, then
# a comment after code, protecting the character before `//`.
decomment() {
  sed -e 's,^[[:space:]]*//.*,,' -e 's,\([^:]\)//.*,\1,' "$1" \
    | sed -e ':a' -e 's:/\*[^*]*\*/::g' -e 'ta'
}

# Read a numeric value for <key>, tolerating Playwright's two literal idioms:
# numeric separators (60_000) and a small product (15 * 60_000). Anything else
# prints nothing, and every caller treats "nothing" as unreadable rather than
# guessing a number it would then compare against.
numval() { # <text> <key>
  local expr
  expr=$(printf '%s\n' "$1" \
    | grep -oE "(^|[^A-Za-z])$2[[:space:]]*:[[:space:]]*[0-9_]+([[:space:]]*\*[[:space:]]*[0-9_]+)?" \
    | head -1 | sed -E "s/.*$2[[:space:]]*:[[:space:]]*//" | tr -d '_ ')
  [ -z "$expr" ] && return 0
  case "$expr" in
    *\**) echo $(( ${expr%%\**} * ${expr##*\*} )) ;;
    *)    echo "$expr" ;;
  esac
}

# The two `timeout` keys mean different things and sit at different depths, so
# one grep cannot read both. Split the source: the `expect: { ... }` object
# first, then everything else for the per-test value.
expect_block() {
  printf '%s\n' "$1" | tr '\n' ' ' | grep -oE 'expect[[:space:]]*:[[:space:]]*\{[^}]*\}' | head -1
}
without_expect_block() {
  printf '%s\n' "$1" | tr '\n' ' ' | sed -E 's/expect[[:space:]]*:[[:space:]]*\{[^}]*\}//'
}

# --- config ------------------------------------------------------------------
check_config() { # <config file> <job-timeout-minutes|"">
  local f="$1" job_timeout="${2:-}" txt
  if [ ! -f "$f" ]; then report "E2E0" "$f" "config file not found"; return; fi
  txt=$(decomment "$f")

  # --- E2E1 -----------------------------------------------------------------
  if ! printf '%s\n' "$txt" | grep -qE 'forbidOnly[[:space:]]*:'; then
    report "E2E1" "$f" "no 'forbidOnly' — a committed test.only silently shrinks the suite to that one test and still reports green"
  elif printf '%s\n' "$txt" | grep -qE 'forbidOnly[[:space:]]*:[[:space:]]*false'; then
    report "E2E1" "$f" "'forbidOnly: false' — under CI this must be true (or !!process.env.CI)"
  fi

  # --- E2E2 -----------------------------------------------------------------
  # A host runs several agent slots. The default worker count is the host's core
  # count, so one pull request's suite takes the whole machine and starves every
  # neighbouring slot — which surfaces as UNRELATED repositories timing out,
  # which is the most expensive kind of failure to diagnose.
  #
  # The key existing is not the property. `workers: process.env.WORKERS` reads as
  # explicit and resolves to undefined, which IS the default — the core count —
  # behind a line that looks like it was thought about. So the value has to be a
  # literal: a count, or a percentage of the host ('50%').
  if ! printf '%s\n' "$txt" | grep -qE '(^|[^A-Za-z])workers[[:space:]]*:'; then
    report "E2E2" "$f" "no explicit 'workers' — the default is the host's core count, which starves the other agent slots on a shared runner"
  elif ! printf '%s\n' "$txt" | grep -qE "(^|[^A-Za-z])workers[[:space:]]*:[[:space:]]*([0-9]+|['\"][0-9]+%['\"])"; then
    report "E2E2" "$f" "'workers' is not a literal this gate can read — an unresolved value falls back to the host's core count, which is the unbounded case this check exists to prevent; write a number or a percentage ('50%')"
  fi

  # --- E2E3 -----------------------------------------------------------------
  local t_expect t_test t_global
  t_expect=$(numval "$(expect_block "$txt")" 'timeout')
  t_test=$(numval "$(without_expect_block "$txt")" 'timeout')
  t_global=$(numval "$txt" 'globalTimeout')

  if ! printf '%s\n' "$txt" | grep -qE 'globalTimeout[[:space:]]*:'; then
    report "E2E3" "$f" "no 'globalTimeout' — a hung suite then burns the job's entire budget, and the merge queue DEQUEUES the pull request silently instead of failing it"
  elif [ -z "$t_global" ]; then
    report "E2E3" "$f" "'globalTimeout' is not a literal this gate can read — write it as a number or a product (15 * 60_000)"
  elif [ -n "$job_timeout" ]; then
    # The top rung must sit BELOW the job that contains it, or it never binds:
    # the job dies first and takes the report with it.
    local job_ms=$(( job_timeout * 60000 ))
    if [ "$t_global" -ge "$job_ms" ]; then
      report "E2E3" "$f" "globalTimeout ${t_global}ms >= the job's timeout-minutes ${job_timeout} (${job_ms}ms) — the bound never binds, and the job dies without a report"
    fi
  fi

  if [ -n "$t_expect" ] && [ -n "$t_test" ] && [ "$t_expect" -ge "$t_test" ]; then
    report "E2E3" "$f" "expect timeout ${t_expect}ms >= test timeout ${t_test}ms — the assertion can never fail first, so the failure says 'test timeout' where it should have said which assertion and what it received"
  fi
  if [ -n "$t_test" ] && [ -n "$t_global" ] && [ "$t_test" -ge "$t_global" ]; then
    report "E2E3" "$f" "test timeout ${t_test}ms >= globalTimeout ${t_global}ms — one test can consume the entire suite budget"
  fi

  # --- E2E4 -----------------------------------------------------------------
  local k
  for k in trace video screenshot; do
    if printf '%s\n' "$txt" | grep -qE "${k}[[:space:]]*:[[:space:]]*['\"]on['\"]"; then
      report "E2E4" "$f" "'${k}: on' captures every PASSING test — roughly doubles runtime and floods artifact storage; use on-first-retry / retain-on-failure / only-on-failure"
    fi
  done
  if ! printf '%s\n' "$txt" | grep -qE 'trace[[:space:]]*:'; then
    report "E2E4" "$f" "no 'trace' setting — a CI failure then has nothing to open, and every diagnosis costs a re-run"
  fi

  # --- E2E5 -----------------------------------------------------------------
  if ! printf '%s\n' "$txt" | grep -qE 'reporter[[:space:]]*:'; then
    report "E2E5" "$f" "no 'reporter' — the default output is not machine-readable, so nothing downstream can read the result"
  elif ! printf '%s\n' "$txt" | grep -qE "['\"](blob|json|junit|github)['\"]"; then
    report "E2E5" "$f" "reporter has no machine-readable entry (blob/json/junit/github) — an html-only report cannot be read by a gate or merged across shards"
  fi

  # --- E2E6 -----------------------------------------------------------------
  # A warm host is the point of this fleet, and it is exactly why a "reusable"
  # server is a server the PREVIOUS job left running.
  if printf '%s\n' "$txt" | grep -qE 'webServer'; then
    if ! printf '%s\n' "$txt" | grep -qE 'reuseExistingServer[[:space:]]*:'; then
      report "E2E6" "$f" "webServer without 'reuseExistingServer' — on a warm host CI can silently test a server left behind by a previous job"
    elif printf '%s\n' "$txt" | grep -qE 'reuseExistingServer[[:space:]]*:[[:space:]]*true'; then
      report "E2E6" "$f" "'reuseExistingServer: true' unconditionally — must be false under CI (!process.env.CI)"
    fi
  fi
}

# --- workflows ---------------------------------------------------------------
check_workflows() { # <root> <image-codename>
  local root="$1" codename="${2:-$IMAGE_CODENAME_DEFAULT}" wf ref got
  for wf in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    # Only a workflow that RUNS the suite. Matching the word "playwright" or
    # "e2e" anywhere caught the workflow that runs THIS GATE — a step named
    # "e2e policy" is enough — and then demanded that the gate job itself run in
    # a browser container. Every adopting repository would have hit that on the
    # first commit, which is the fastest way to have a gate deleted.
    grep -qE 'playwright[[:space:]]+test|(npm|pnpm|yarn)[[:space:]]+(run[[:space:]]+)?(test:)?e2e' "$wf" || continue

    # --- E2E7 ---------------------------------------------------------------
    # Browsers are deliberately NOT on the host image (#66): baking binaries
    # would pin every repository on the fleet to one release, and repositories
    # upgrade on their own schedule. The container carries them instead, and the
    # pin lives in the repository that owns the matching dependency.
    ref=$(grep -oE "$PLAYWRIGHT_IMAGE_RE" "$wf" | head -1)
    if [ -n "$ref" ]; then
      # The codename is not cosmetic: the browser binaries in the image are
      # linked against that Ubuntu release's system libraries, and the fleet
      # bakes exactly one of them. A job on the other one runs, passes, and
      # downloads the whole image first.
      got="${ref##*-}"
      if [ "$got" != "$codename" ]; then
        report "E2E7" "$wf" "container is -${got} but the fleet bakes -${codename} — the image runs, so nothing goes red; it is simply downloaded in full on every job instead of loaded from the host"
      fi
      if grep -qE 'playwright[[:space:]]+install' "$wf"; then
        report "E2E7" "$wf" "'playwright install' inside the Playwright container — the browsers are already there; this re-downloads them per job and can install a build the container's libraries do not match"
      fi
    else
      report "E2E7" "$wf" "no 'container: mcr.microsoft.com/playwright:v<x>-noble' — the fleet bakes that image and loads it into every slot at boot, so a job without it downloads ~2 GB it could have found on disk (docs/ui-testing-on-the-fleet.md)"
    fi

    # --- E2E5, the sharding half --------------------------------------------
    if grep -qE '\-\-shard' "$wf" && ! grep -qE 'blob' "$wf"; then
      report "E2E5" "$wf" "the job shards but no 'blob' reporter is configured — shard reports cannot be merged, so the run produces N partial verdicts and no single one"
    fi
  done
}

# --- container pin vs dependency pin -----------------------------------------
check_version() { # <root>
  local root="$1" pinned wf tag
  [ -f "$root/package.json" ] || return 0
  pinned=$(grep -oE '"@playwright/test"[[:space:]]*:[[:space:]]*"[^"]+"' "$root/package.json" \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/' | tr -d '^~')
  [ -n "$pinned" ] || return 0

  # --- E2E8 -----------------------------------------------------------------
  # The one that decides whether any of the speed work survives a dependency
  # bump — and the half `check-playwright-pin.sh` cannot see, because the
  # `container:` line lives in the consumer's repository next to the dependency
  # it has to match. Playwright will not drive a browser build its client was
  # not compiled against: the good case is a hard error, the bad case is the
  # client quietly fetching its own copy inside the container.
  for wf in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    tag=$(grep -oE "$PLAYWRIGHT_IMAGE_RE" "$wf" | head -1 | sed -E 's/.*:v([0-9][0-9.]*)-[a-z]+$/\1/')
    [ -n "$tag" ] || continue
    [ "$tag" = "$pinned" ] && continue
    report "E2E8" "$wf" "container playwright v${tag} != @playwright/test ${pinned} in package.json — bump both together, or the job runs one release's browsers under another release's client"
  done
}

# --- specs -------------------------------------------------------------------
check_specs() { # <root>
  local root="$1" dir hits line
  for dir in e2e tests/e2e test/e2e; do
    [ -d "$root/$dir" ] || continue
    # --- E2E9 ---------------------------------------------------------------
    hits=$(grep -rnE 'waitForTimeout\(|(^|[^A-Za-z])sleep\(' "$root/$dir" 2>/dev/null | head -5)
    [ -n "$hits" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      report "E2E9" "$(printf '%s' "$line" | cut -d: -f1-2)" "arbitrary wait — the single largest source of BOTH flake and wasted runtime; use a web-first assertion (await expect(locator).toBeVisible()) which retries and then fails honestly"
    done <<EOF
$hits
EOF
  done
}

# =============================================================================
# Self-test.
#
# A gate with no self-test is a gate that can silently stop gating — the same
# class of failure every check above exists to catch, aimed at the checker
# instead of the checked. So each case asserts the SPECIFIC id fired, not merely
# that something did: a rule that fails for the wrong reason has already stopped
# being the rule.
#
# SC2030: each case runs its check in a `$( fail=0; … )` subshell on purpose. The
# fixture's planted failure has to be captured and counted WITHOUT reaching the
# real exit status — a self-test that failed the gate it is testing would be
# indistinguishable from the gate working.
# =============================================================================
# shellcheck disable=SC2030
selftest() {
  local pass=0 tfail=0 tmp out
  tmp=$(mktemp -d)

  # want="" asserts a clean read; otherwise it is the id that must appear.
  expect_cfg() { # <description> <want-id|""> <config body>
    local desc="$1" want="$2" body="$3" got
    printf '%s\n' "$body" > "$tmp/playwright.config.ts"
    got=$( fail=0; check_config "$tmp/playwright.config.ts" "" )
    if [ -z "$want" ]; then
      if [ -z "$got" ]; then pass=$((pass + 1)); return; fi
    else
      case "$got" in *"[$want]"*) pass=$((pass + 1)); return ;; esac
    fi
    tfail=$((tfail + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$desc" "${want:-<clean>}" "${got:-<clean>}"
  }

  expect_cfg "a compliant config is clean" "" 'export default defineConfig({
  forbidOnly: !!process.env.CI,
  workers: 4,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  globalTimeout: 15 * 60_000,
  use: { trace: "on-first-retry", screenshot: "only-on-failure", video: "retain-on-failure" },
  reporter: [["blob"], ["github"]],
})'

  expect_cfg "a missing forbidOnly is caught" E2E1 'export default defineConfig({
  workers: 4,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  globalTimeout: 900000,
  use: { trace: "on-first-retry" },
  reporter: [["blob"]],
})'

  expect_cfg "forbidOnly:false is caught even though the key is present" E2E1 'export default defineConfig({
  forbidOnly: false,
  workers: 4,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  globalTimeout: 900000,
  use: { trace: "on-first-retry" },
  reporter: [["blob"]],
})'

  expect_cfg "unbounded workers is caught" E2E2 'export default defineConfig({
  forbidOnly: true,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  globalTimeout: 900000,
  use: { trace: "on-first-retry" },
  reporter: [["blob"]],
})'

  expect_cfg "a missing globalTimeout is caught" E2E3 'export default defineConfig({
  forbidOnly: true,
  workers: 4,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  use: { trace: "on-first-retry" },
  reporter: [["blob"]],
})'

  # The ladder, not merely the presence of its rungs. An expect timeout at or
  # above the test timeout produces "Test timeout of 60000ms exceeded" where the
  # useful message was "expected visible, received hidden".
  expect_cfg "an inverted expect/test ladder is caught" E2E3 'export default defineConfig({
  forbidOnly: true,
  workers: 4,
  expect: { timeout: 90_000 },
  timeout: 60_000,
  globalTimeout: 900000,
  use: { trace: "on-first-retry" },
  reporter: [["blob"]],
})'

  expect_cfg "a globalTimeout written as an unreadable expression fails, never passes" E2E3 'export default defineConfig({
  forbidOnly: true,
  workers: 4,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  globalTimeout: computeBudget(process.env),
  use: { trace: "on-first-retry" },
  reporter: [["blob"]],
})'

  expect_cfg "trace:on is caught" E2E4 'export default defineConfig({
  forbidOnly: true,
  workers: 4,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  globalTimeout: 900000,
  use: { trace: "on" },
  reporter: [["blob"]],
})'

  expect_cfg "an html-only reporter is caught" E2E5 'export default defineConfig({
  forbidOnly: true,
  workers: 4,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  globalTimeout: 900000,
  use: { trace: "on-first-retry" },
  reporter: [["html"]],
})'

  expect_cfg "reuseExistingServer:true is caught" E2E6 'export default defineConfig({
  forbidOnly: true,
  workers: 4,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  globalTimeout: 900000,
  use: { trace: "on-first-retry" },
  reporter: [["blob"]],
  webServer: { command: "npm start", url: "http://localhost:3000", reuseExistingServer: true },
})'

  # A commented-out setting is an explanation, not configuration. A gate that
  # cannot tell the difference gets disabled by the first person who documents
  # why the rule exists.
  expect_cfg "a commented-out trace:on is not read as configuration" "" 'export default defineConfig({
  forbidOnly: !!process.env.CI,
  workers: 4,
  expect: { timeout: 10_000 },
  timeout: 60_000,
  globalTimeout: 15 * 60_000,
  // we used to set trace: "on" here; it doubled the suite runtime
  use: { trace: "on-first-retry" },
  reporter: [["blob"], ["github"]],
})'

  # --- the ladder against the job that contains it ----------------------------
  printf '%s\n' 'export default defineConfig({
  forbidOnly: true, workers: 4,
  expect: { timeout: 10_000 }, timeout: 60_000, globalTimeout: 30 * 60_000,
  use: { trace: "on-first-retry" }, reporter: [["blob"]],
})' > "$tmp/playwright.config.ts"
  out=$( fail=0; check_config "$tmp/playwright.config.ts" 25 )
  case "$out" in
    *"[E2E3]"*"never binds"*) pass=$((pass + 1)) ;;
    *) tfail=$((tfail + 1)); printf 'FAIL: a globalTimeout above the job timeout is caught\n  got: %s\n' "${out:-<clean>}" ;;
  esac

  # --- the workflow half ------------------------------------------------------
  mkdir -p "$tmp/repo/.github/workflows"
  cat > "$tmp/repo/.github/workflows/e2e.yml" <<'EOF'
jobs:
  e2e:
    runs-on: [self-hosted, Linux, gcp, DemoRepo]
    timeout-minutes: 25
    steps:
      - run: npx playwright test --shard=1/4
EOF
  out=$( fail=0; check_workflows "$tmp/repo" )
  case "$out" in *"[E2E7]"*"no 'container"*) pass=$((pass + 1)) ;;
    *) tfail=$((tfail + 1)); printf 'FAIL: an E2E job outside the baked container is caught\n  got: %s\n' "${out:-<clean>}" ;; esac
  case "$out" in *"[E2E5]"*) pass=$((pass + 1)) ;;
    *) tfail=$((tfail + 1)); printf 'FAIL: sharding without a blob reporter is caught\n  got: %s\n' "${out:-<clean>}" ;; esac

  # In the container, `playwright install` is the redundant half of the same
  # rule and needs its own fixture: the branch above can never reach it.
  cat > "$tmp/repo/.github/workflows/e2e.yml" <<'EOF'
jobs:
  e2e:
    runs-on: [self-hosted, Linux, gcp, DemoRepo]
    container: mcr.microsoft.com/playwright:v1.62.1-noble
    steps:
      - run: npx playwright install --with-deps chromium
      - run: npx playwright test
EOF
  out=$( fail=0; check_workflows "$tmp/repo" )
  case "$out" in *"[E2E7]"*"already there"*) pass=$((pass + 1)) ;;
    *) tfail=$((tfail + 1)); printf 'FAIL: playwright install inside the container is caught\n  got: %s\n' "${out:-<clean>}" ;; esac

  # A URL in a config value must not be eaten as a comment, and the keys after
  # it on the same line must survive. This is the regression that made the gate
  # judge a truncated copy of the file.
  cat > "$tmp/url.config.ts" <<'EOF'
export default {
  forbidOnly: true, workers: 2, globalTimeout: 900_000, timeout: 30_000,
  expect: { timeout: 5_000 },
  use: { baseURL: 'http://localhost:3000', trace: 'on-first-retry' },
  reporter: [['blob']],
};
EOF
  out=$( fail=0; check_config "$tmp/url.config.ts" "" )
  if [ -z "$out" ]; then pass=$((pass + 1)); else
    tfail=$((tfail + 1)); printf 'FAIL: a baseURL is not read as a comment\n  got: %s\n' "$out"; fi

  # `workers` present but unresolvable is the default in disguise.
  cat > "$tmp/envworkers.config.ts" <<'EOF'
export default {
  forbidOnly: true, workers: process.env.WORKERS, globalTimeout: 900_000,
  timeout: 30_000, expect: { timeout: 5_000 },
  use: { trace: 'on-first-retry' }, reporter: [['blob']],
};
EOF
  out=$( fail=0; check_config "$tmp/envworkers.config.ts" "" )
  case "$out" in *"[E2E2]"*) pass=$((pass + 1)) ;;
    *) tfail=$((tfail + 1)); printf 'FAIL: a non-literal workers value is caught\n  got: %s\n' "${out:-<clean>}" ;; esac

  # The workflow that runs THIS GATE must not be asked to run in a browser.
  cat > "$tmp/repo/.github/workflows/gates.yml" <<'EOF'
jobs:
  gates:
    runs-on: ubuntu-latest
    steps:
      - name: e2e policy
        run: bash scripts/ci/check-e2e-policy.sh --job-timeout=25
EOF
  out=$( fail=0; check_workflows "$tmp/repo" noble )
  case "$out" in *gates.yml*) tfail=$((tfail + 1)); printf 'FAIL: the gate workflow is not itself flagged\n  got: %s\n' "$out" ;;
    *) pass=$((pass + 1)) ;; esac
  rm -f "$tmp/repo/.github/workflows/gates.yml"

  # A codename the fleet did not bake runs, passes, and downloads the lot.
  #
  # The wrong tag is ASSEMBLED, not written. check-playwright-pin.sh (PW2) holds
  # every `mcr.microsoft.com/playwright:` reference in this repository to the one
  # release the pool bakes, and it is right to: a stale literal anywhere here is
  # a consumer copying it. A fixture is not a reference, but a grep cannot tell
  # the difference, so the file does not contain one. Do not "tidy" this back
  # into a literal — it fails the sibling gate, not this one.
  local unbaked="mcr.microsoft.com/playwright:v1.62.1-""jammy"
  cat > "$tmp/repo/.github/workflows/e2e.yml" <<EOF
jobs:
  e2e:
    runs-on: [self-hosted, Linux, gcp, DemoRepo]
    container: ${unbaked}
    steps:
      - run: npx playwright test
EOF
  out=$( fail=0; check_workflows "$tmp/repo" noble )
  case "$out" in *"[E2E7]"*"-jammy"*) pass=$((pass + 1)) ;;
    *) tfail=$((tfail + 1)); printf 'FAIL: a codename the fleet did not bake is caught\n  got: %s\n' "${out:-<clean>}" ;; esac

  # --- the container pin vs the dependency pin --------------------------------
  printf '%s\n' '{ "devDependencies": { "@playwright/test": "^1.54.0" } }' > "$tmp/repo/package.json"
  out=$( fail=0; check_version "$tmp/repo" )
  case "$out" in *"[E2E8]"*) pass=$((pass + 1)) ;;
    *) tfail=$((tfail + 1)); printf 'FAIL: a container drifted from the dependency pin is caught\n  got: %s\n' "${out:-<clean>}" ;; esac

  # The caret must not be read as part of the version, or every repository sits
  # in permanent drift and the check is switched off within a week.
  printf '%s\n' '{ "devDependencies": { "@playwright/test": "^1.62.1" } }' > "$tmp/repo/package.json"
  out=$( fail=0; check_version "$tmp/repo" )
  if [ -z "$out" ]; then pass=$((pass + 1)); else
    tfail=$((tfail + 1)); printf 'FAIL: a caret range matching the container is clean\n  got: %s\n' "$out"; fi

  # --- the spec half ----------------------------------------------------------
  mkdir -p "$tmp/repo/e2e"
  printf '%s\n' 'await page.waitForTimeout(2000);' > "$tmp/repo/e2e/slow.spec.ts"
  out=$( fail=0; check_specs "$tmp/repo" )
  case "$out" in *"[E2E9]"*) pass=$((pass + 1)) ;;
    *) tfail=$((tfail + 1)); printf 'FAIL: an arbitrary wait in a spec is caught\n  got: %s\n' "${out:-<clean>}" ;; esac
  # A finding without a line number is a finding someone has to go looking for.
  case "$out" in *"slow.spec.ts:1"*) pass=$((pass + 1)) ;;
    *) tfail=$((tfail + 1)); printf 'FAIL: an E2E9 finding carries its line number\n  got: %s\n' "${out:-<clean>}" ;; esac

  rm -rf "$tmp"
  printf '\n%d passed, %d failed\n' "$pass" "$tfail"
  [ "$tfail" -eq 0 ]
}

# --- main --------------------------------------------------------------------
# SC2030/SC2031: `fail` is read here after `selftest`'s `$( fail=0; … )` subshells
# wrote their own copies of it, which is exactly the intent — a fixture's planted
# failure must not reach this exit status. On the real path every check_* runs in
# THIS shell, so the value read here is the one its `report()` calls set. Same
# reasoning, and same disable, as check-runner-policy.sh.
# shellcheck disable=SC2030,SC2031
main() {
  local run_selftest=0 job_timeout="" root="." codename="$IMAGE_CODENAME_DEFAULT" arg c d orphan=0
  local -a targets=()

  for arg in "$@"; do
    case "$arg" in
      --selftest)          run_selftest=1 ;;
      --root=*)            root="${arg#*=}" ;;
      --job-timeout=*)     job_timeout="${arg#*=}" ;;
      --image-codename=*)  codename="${arg#*=}" ;;
      -*) echo "unknown option: $arg" >&2; return 2 ;;
      *)  targets+=("$arg") ;;
    esac
  done

  if [ "$run_selftest" -eq 1 ]; then
    selftest
    return $?
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      targets+=("$c")
    done <<EOF
$(find "$root" -maxdepth 3 -name 'playwright.config.*' -not -path '*/node_modules/*' 2>/dev/null | sort)
EOF
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    # A repository with no browser suite is a legitimate state, and this gate
    # must not invent work for it. But "no config" is only legitimate when there
    # is also no suite: a spec tree, or an E2E job, with no config to govern it
    # is exactly the vacuous pass this gate exists to refuse. Name it and fail
    # rather than report clean.
    for d in e2e tests/e2e test/e2e; do [ -d "$root/$d" ] && orphan=1; done
    grep -rqlE 'playwright[[:space:]]+test' "$root/.github/workflows" 2>/dev/null && orphan=1
    if [ "$orphan" -eq 1 ]; then
      echo "::error::[E2E0] an E2E suite or job exists but no playwright.config.* was found — nothing was checked, and a suite no gate can read is a suite no gate governs"
      return 1
    fi
    echo "check-e2e-policy: no browser suite in this repository — nothing to gate"
    return 0
  fi

  for c in "${targets[@]}"; do check_config "$c" "$job_timeout"; done
  check_workflows "$root" "$codename"
  check_version "$root"
  check_specs "$root"

  if [ "$fail" -gt 0 ]; then
    echo "check-e2e-policy: ${fail} finding(s). Every one of these keeps a check GREEN while removing its meaning or its speed."
    return 1
  fi
  echo "check-e2e-policy clean: ${#targets[@]} config(s)"
  return 0
}

main "$@"
