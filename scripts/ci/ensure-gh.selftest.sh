#!/usr/bin/env bash
# Self-test for ensure-gh.sh's download paths, with curl stubbed and no network.
#
# What it pins: when the release download fails, the same asset is asked for
# from the releases API (octet-stream, the job's token when there is one), and
# whatever arrives by either path still has to match the pinned digest. The
# stub never serves the real tarball, so every run ends at the checksum — which
# is the point: no path may install bytes the digest did not approve.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/ensure-gh.sh"
bash_bin="$(command -v bash)"
fail=0

# The caller's PATH minus every directory holding a gh, so the script cannot
# exit early on a runner image that ships the CLI, with the curl stub in front.
# (Filtering rather than symlinking a tool list: a symlinked binary outside its
# own directory cannot find its libraries on every platform.)
no_gh_path=""
IFS=: read -r -a path_dirs <<< "$PATH"
for p in "${path_dirs[@]}"; do
  [ -n "$p" ] && [ ! -e "$p/gh" ] && [ ! -e "$p/gh.exe" ] && no_gh_path="${no_gh_path:+$no_gh_path:}$p"
done

sandbox() { # <dir>
  mkdir -p "$1/bin"
  cat > "$1/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"; url="$a"
done
printf '%s\n' "$*" >> "$STUB_LOG"
case "$url" in
  *releases/download/*) [ "$STUB_PRIMARY" = ok ] || exit 22 ;;
  *api.github.com/*/releases/assets/*) [ "$STUB_API" = ok ] || exit 22 ;;
  *) exit 6 ;;
esac
printf 'not the gh tarball\n' > "$out"
STUB
  chmod +x "$1/bin/curl"
}

# <name> <primary ok|fail> <api ok|fail> <token or ""> <check...>
run_case() {
  local name="$1" primary="$2" api="$3" token="$4"; shift 4
  local d; d="$(mktemp -d)"
  sandbox "$d"
  local rc=0
  env -i PATH="$d/bin:$no_gh_path" HOME="$d" RUNNER_TEMP="$d/rt" STUB_LOG="$d/log" \
    STUB_PRIMARY="$primary" STUB_API="$api" ${token:+GH_TOKEN="$token"} \
    "$bash_bin" "$script" > "$d/out" 2>&1 || rc=$?
  touch "$d/log"
  local ok=1 c
  for c in "$@"; do
    case "$c" in
      rc!=0) [ "$rc" -ne 0 ] || ok=0 ;;
      api) grep -q 'api.github.com/repos/cli/cli/releases/assets/52285790[12]' "$d/log" || ok=0 ;;
      no-api) ! grep -q 'api.github.com' "$d/log" || ok=0 ;;
      octet) grep 'api.github.com' "$d/log" | grep -q 'Accept: application/octet-stream' || ok=0 ;;
      bearer) grep 'api.github.com' "$d/log" | grep -q "Authorization: Bearer $token" || ok=0 ;;
      no-auth) ! grep -q 'Authorization' "$d/log" || ok=0 ;;
      checksum) grep -q 'checksum mismatch' "$d/out" || ok=0 ;;
      no-install) [ ! -e "$d/rt/bin/gh" ] || ok=0 ;;
    esac
    if [ "$ok" -eq 0 ]; then
      echo "FAIL $name: check '$c' (rc=$rc)"
      sed 's/^/  out: /' "$d/out"; sed 's/^/  curl: /' "$d/log"
      fail=1; rm -rf "$d"; return
    fi
  done
  echo "ok   $name"
  rm -rf "$d"
}

run_case "a failed release download falls back to the API asset, with the token" \
  fail ok "t0k-123" api octet bearer checksum no-install rc!=0
run_case "the fallback goes anonymous when the job has no token" \
  fail ok "" api octet no-auth checksum no-install rc!=0
run_case "a working release download never asks the API" \
  ok ok "t0k-123" no-api checksum no-install rc!=0
run_case "both paths failing installs nothing" \
  fail fail "t0k-123" api no-install rc!=0

exit "$fail"
