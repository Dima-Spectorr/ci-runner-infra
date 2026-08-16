#!/usr/bin/env bash
# The scanner, against a repository built for the purpose and a pinned feed.
#
# HERMETIC ON PURPOSE. The scan reads a third-party API in production; this
# self-test never does. A gate whose result depends on endoflife.date being up
# is a gate that goes red for a reason no pull request caused, and the fix for
# that kind of red is always to delete the gate.
#
# The feed fixtures below are real values transcribed from the API on
# 2026-08-16, trimmed to the cycles each assertion needs.
#
# Several needles are single-quoted Markdown containing backticks, read as a
# command substitution nobody expanded (SC2016). They are literal report text —
# the assertion is that the report says `.nvmrc`, backticks and all — so those
# sites carry a bare disable rather than being rewritten into something that no
# longer matches what a reader sees.
#
# Note the wrapping: a comment line STARTING with the tool's own name is parsed
# as a directive, so this paragraph never begins a line with it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$HERE/scan-support-windows.sh"
TODAY=2026-08-16

PASS=0
FAIL=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; PASS=$((PASS + 1))
  else printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}
has() { # has <label> <needle> — the report contains it
  if grep -qF -- "$2" "$REPORT"; then printf 'ok   %s\n' "$1"; PASS=$((PASS + 1))
  else printf 'FAIL %s — report has no "%s"\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi
}
hasnt() { # hasnt <label> <needle>
  if grep -qF -- "$2" "$REPORT"; then printf 'FAIL %s — report should not mention "%s"\n' "$1" "$2"; FAIL=$((FAIL + 1))
  else printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
CACHE="$WORK/cache"
REPORT="$WORK/report.md"
mkdir -p "$REPO/.github/workflows" "$REPO/packer" "$CACHE"

# --- the pinned feed ---------------------------------------------------------
cat >"$CACHE/nodejs.json" <<'EOF'
[{"cycle":"26","lts":"2026-10-28","eol":"2029-04-30","support":"2027-10-27"},
 {"cycle":"24","lts":"2025-10-28","eol":"2028-04-30","support":"2026-10-20"},
 {"cycle":"22","lts":"2024-10-29","eol":"2027-04-30","support":"2025-10-21"},
 {"cycle":"20","lts":"2023-10-24","eol":"2026-04-30","support":"2024-10-22"},
 {"cycle":"18","lts":"2022-10-25","eol":"2025-04-30","support":"2023-10-18"}]
EOF
cat >"$CACHE/react.json" <<'EOF'
[{"cycle":"19","eol":false,"lts":false,"support":true},
 {"cycle":"18","eol":false,"lts":false,"support":"2024-12-05"}]
EOF
cat >"$CACHE/go.json" <<'EOF'
[{"cycle":"1.24","eol":false,"lts":false,"support":true},
 {"cycle":"1.21","eol":"2024-08-13","lts":false,"support":"2024-02-06"}]
EOF
cat >"$CACHE/ubuntu.json" <<'EOF'
[{"cycle":"24.04","lts":true,"eol":"2029-05-31","support":"2029-05-31"}]
EOF

# --- the repository under test -----------------------------------------------
echo '18.20.4' >"$REPO/.nvmrc"
printf 'FROM node:20-bookworm\nFROM scratch\n' >"$REPO/Dockerfile"
printf 'module example\n\ngo 1.21\n' >"$REPO/go.mod"
cat >"$REPO/package.json" <<'EOF'
{"dependencies":{"react":"^18.3.1","left-pad":"^1.3.0","lodash":"4.17.21"}}
EOF
cat >"$REPO/.github/workflows/build.yml" <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/setup-node
        with:
          node-version: '20.x'
EOF
cat >"$REPO/packer/image.pkr.hcl" <<'EOF'
variable "source_image_family" {
  default = "ubuntu-2404-lts-amd64"
}
variable "node_major" {
  type        = string
  description = <<-EOT
    A description long enough to push the default past any fixed grep context
    window, which is exactly how the real file is written.
  EOT
  default     = "22"
}
EOF

run() { bash "$SCAN" --repo-root "$REPO" --cache "$CACHE" --today "$TODAY" \
        --out "$REPORT" --offline "$@"; }

# --- the scan reads every place a version is chosen --------------------------
run
check "the scan exits 0 — findings are the report, never the exit code" 0 "$?"

# shellcheck disable=SC2016
has "a .nvmrc runtime is read"            '`.nvmrc`'
has "a Dockerfile base image is read"     'Dockerfile'
# shellcheck disable=SC2016
has "a go.mod language version is read"   '`go.mod`'
has "a workflow setup-* step is read"     'build.yml'
has "a tracked framework in package.json is read" 'package.json'

# The image half. No manifest names it, no Dependabot ecosystem covers it, and
# it is inherited by every host in the fleet.
has "the golden image's baked node is read" 'image.pkr.hcl'

# The `default` sits after a multi-line heredoc description — the shape that
# defeated a `grep -A4` and reported the image clean.
# shellcheck disable=SC2016
has "the baked node major is 22, read past its heredoc description" '| `nodejs` | 22 |'

# The host OS is supported, so its evidence is an ABSENCE. `ubuntu-2404-lts`
# has to become the cycle `24.04`: a major-only `24` matches nothing in the
# feed, and would report the operating system under every host in the fleet as
# undecided while looking like a scan that ran.
hasnt "the host OS resolved against the feed rather than going undecided" \
  'no-lifetime-data-for-24'
has "…and it is the one fully-supported declaration in this fixture" \
  '1 declaration(s) are fully supported'

# --- the verdicts ------------------------------------------------------------
has "Node 18 is unsupported"  'unsupported-since-2025-04-30'
has "Node 20 is unsupported"  'unsupported-since-2026-04-30'
has "go 1.21 is unsupported"  'unsupported-since-2024-08-13'
has "React 18 has no EOL date but ended support" 'support-ended-2024-12-05'
has "the baked Node 22 is maintenance-only, not a failure" 'maintenance-only-since-2025-10-21'
has "the unsupported findings lead the report" 'Unsupported — running past end of support'

# A supported declaration produces no row at all. Ubuntu 24.04 is supported
# until 2029 and must be invisible here — a report that lists what is fine
# alongside what is not is a report nobody finishes reading.
# shellcheck disable=SC2016
hasnt "a supported version is not reported" '`ubuntu`'

# --- a library with no published lifetime is NOT a finding -------------------
# This is the line between a report people read and a report people mute. No
# feed tracks left-pad; inventing a row for it — and for the two thousand like
# it in a real lockfile — would bury every row above.
hasnt "an untracked library raises no row" 'left-pad'
hasnt "an untracked library raises no row (lodash)" 'lodash'
has "…but the report says so, rather than implying it scanned them" \
  'Libraries without a published support lifetime are not scanned'

# --- the report is whole -----------------------------------------------------
# It was not, once: writing it through a `> /dev/stdout` redirect truncated
# everything before the first finding, on a platform where that path is not a
# plain file. A half-written report still looks like a report.
check "the report starts at its first byte" '<!-- support-window-scan -->' "$(head -n1 "$REPORT")"

# --- a NEW declaration is judged more strictly than an inherited one ---------
# Same version, same feed, different verdict — the only input that changed is
# whether this pull request introduced it.
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email selftest@example.invalid
git -C "$REPO" config user.name selftest
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm base >/dev/null 2>&1
BASE="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"

# A new service arrives on Node 22 while 24 is on the shelf, supported for
# another year. On the day of the pull request this costs one character to fix.
mkdir -p "$REPO/services/new"
printf 'FROM node:22-bookworm\n' >"$REPO/services/new/Dockerfile"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm "new service" >/dev/null 2>&1

run --base-ref "$BASE"
has "a newly adopted maintenance-only line names the alternative" \
  'new-on-maintenance-22-choose-24'
has "…under a heading about the choice, not about the version" \
  'Newly adopted with a shorter runway'

# The identical version, inherited rather than introduced, stays informational.
has "the same version inherited elsewhere is still only maintenance-only" \
  'maintenance-only-since-2025-10-21'

# --- "new" is a question about ONE file ---------------------------------------
#
# The regression this exists for. The first version pooled every added line in
# the diff and matched a piece of evidence TEXT against it, so a declaration was
# judged newly chosen because some unrelated file happened to contain the same
# words. It fired for real on the pull request that shipped this scanner: the
# evidence text for the Packer row was the literal string `node_major default`,
# the scanner's own source contains it, and the report announced that the pull
# request had just adopted the golden image's node 22 — a version the branch had
# never touched.
#
# So: add a file that TALKS about the image's declaration without being it, and
# leave the image itself alone. The two lines below are the two ways the match
# can be fooled, and the fixture carries both deliberately:
#
#   1. the old evidence LABEL, contiguously — this is the exact string that
#      fired in production, and prose that merely mentions `node_major` and
#      `default` separately does NOT reproduce it;
#   2. a verbatim copy of the declaration LINE, in a different file — which the
#      label fix alone would not catch, and only per-file scoping does.
mkdir -p "$REPO/docs"
{
  printf 'The image bakes a node major.\n'
  printf 'The report used to label this row: node_major default\n'
  printf 'The Packer file says:     default     = "22"\n'
  printf 'The host OS family is ubuntu-2404-lts-amd64.\n'
} >"$REPO/docs/how-the-image-works.md"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm "document the image" >/dev/null 2>&1

# Both needles name the Packer row specifically. The Dockerfile added earlier is
# still genuinely new in this same diff, so a bare `new-on-...` needle would be
# satisfied by the row that is SUPPOSED to be there and assert nothing.
run --base-ref "$BASE"
hasnt "prose describing a declaration does not adopt it" \
  '`packer/image.pkr.hcl` | new-on'
has "the untouched image declaration stays inherited" \
  '`packer/image.pkr.hcl` | maintenance-only-since-2025-10-21'

# --- an unreachable feed is UNDECIDED, never clean ---------------------------
EMPTY="$WORK/empty-cache"
mkdir -p "$EMPTY"
bash "$SCAN" --repo-root "$REPO" --cache "$EMPTY" --today "$TODAY" \
  --out "$REPORT" --offline
check "a total feed outage still exits 0" 0 "$?"
has "an outage produces undecided rows"     'Undecided — no lifetime data'
has "an outage says the report is incomplete" 'which is not the same as clean'
hasnt "an outage never reports a version as supported" 'Unsupported — running past'

printf 'scan-support-windows selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
