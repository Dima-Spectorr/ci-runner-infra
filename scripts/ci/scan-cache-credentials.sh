#!/usr/bin/env bash
# =============================================================================
# The EMBEDDED-CREDENTIAL CONTENT pass over a cache tree.
#
# WHY THIS IS ITS OWN FILE
#
# `publish-cache-snapshot.sh` refuses a tree whose CONTENT holds a registry
# token, a URL with embedded basic auth or a private key. `build-cache-snapshot.ps1`
# refuses one whose FILENAMES look like a credential store, and until this file
# existed that was all it could do: the content pass lived inline in a bash
# script that cannot run verbatim on `windows-latest`, so a credential a tool
# embedded under a hash-named file crossed the job boundary before anything
# looked at it — and `upload-artifact` makes the archive downloadable by anyone
# who can read the repository the moment it is stored, which is BEFORE the
# publish job's refusal can take it back.
#
# The obvious alternative was a PowerShell port. That would be a THIRD copy of
# security-critical patterns; two copies already need a self-test to keep
# honest, and three is where they drift. So there is one copy, here, and both
# callers run it — the Windows job through git-bash, which is on the image and
# has the GNU find/grep/awk/sha256sum this needs. What it does NOT need is
# `getcap`, setuid bits or device nodes: those are the LINK, CAPABILITY and
# NODE passes, they are meaningless on NTFS, and they stay in the publisher.
#
# HOW IT IS USED
#
#   sourced   `. scan-cache-credentials.sh` — the caller keeps its own `die`,
#             `log` and `safe_path` (this file defines them only if it has to),
#             and calls `scan_credentials_or_die <tree>` where it wants the
#             pass. That is what `publish-cache-snapshot.sh` does, so every
#             refusal it prints still names the publisher.
#   run       `scan-cache-credentials.sh <tree>` — scans and exits non-zero
#             with the reason on stderr. That is what the Windows build job
#             does, over the staged tree, BEFORE `tar`.
#
# INPUTS (environment) — the same two names in both jobs, deliberately:
#   CACHE_SCAN_ALLOW_DIGESTS  full sha256 digests, comma- or whitespace-
#                             separated, of files this pass may excuse.
#   CACHE_SCAN_ALLOW_FILE     a checked-in file of the same digests, one per
#                             line, EACH followed by a `#` comment naming the
#                             package that ships it.
#   SCAN_TMPDIR               optional. Where the hit list is created. Defaults
#                             to a fresh `mktemp -d`. The publisher passes its
#                             own archive directory so the list dies with it.
#
# An entry must be justified by the package name and never by the hash alone;
# see the allowlist block below for why that is enforced rather than asked for.
# =============================================================================

# Sourced or run, decided by whether `return` is legal here. The distinction is
# not cosmetic: run, this file owns the shell and sets its own `-euo pipefail`;
# sourced, it must not reach into the caller's options, because a caller that
# deliberately runs without `-e` would silently get it.
if (return 0 2>/dev/null); then
  SCAN_SOURCED=1
else
  SCAN_SOURCED=0
  set -euo pipefail
fi

# The caller's reporters win. `publish-cache-snapshot.sh` prefixes every line
# with its own name, and a refusal that suddenly named a different script would
# send whoever reads the log to the wrong file. Defined here only when there is
# nothing to defer to, which is the standalone case.
if ! declare -F die >/dev/null 2>&1; then
  die() { printf 'scan-cache-credentials: %s\n' "$*" >&2; exit 1; }
fi
if ! declare -F log >/dev/null 2>&1; then
  log() { printf 'scan-cache-credentials: %s\n' "$*"; }
fi
# A path from the staged tree, made safe to print. The tree is populated by the
# prepare command — third-party install code — and a filename may legally hold a
# newline or an escape sequence. Printed raw into an Actions log, one carrying
# `\n::add-mask::` or `\n::error::` writes workflow commands from the job that
# holds the publishing credential; more cheaply, a newline forges log lines and
# hides the rest of the refusal. Non-printables become `?`, which keeps the fact
# that something was there rather than quietly dropping it.
if ! declare -F safe_path >/dev/null 2>&1; then
  safe_path() { printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' '?'; }
fi

# The content digests the embedded-credential pass may excuse.
#
# It exists because a hit there is not automatically a leak. A dependency's
# PAYLOAD can carry a PEM test fixture — `pnpm install` of one real monorepo
# lands a 4 KiB private key from a package's own tests — and in a
# content-addressed store it arrives under a hash name, so the credential-
# FILENAME pass cannot see it and the content pass refuses that snapshot on every
# run, forever. The two ways out that do not need this are deleting the pattern
# and widening it into uselessness, which is how a scan stops being a bound.
#
# Read from the consumer, not from a list in this repository: which fixture a
# consumer's dependency tree drags in is theirs to know, and the entry belongs in
# their workflow or in a file beside it, on a line next to a comment naming the
# package. It must be set in BOTH jobs — the publishing job re-scans what it
# received, and one excused only in the build job fails there instead.
#
# Validated strictly. A malformed entry that quietly matched nothing would read
# exactly like one that worked, and a SHORT one is the real hazard: treated as a
# prefix it would excuse everything beginning with those characters.
SCAN_ALLOW_DIGESTS=()

# One entry, from either source. `where` names the source in every refusal, so an
# operator staring at "non-hex entry" knows which of the two to go and edit.
SCAN_ALLOW_WHERE=()
scan_allow_add() { # <digest> <where>
  local d=$1 where=$2
  case "$d" in
    *[!0-9a-fA-F]* ) die "$where holds a non-hex entry: $(safe_path "$d")" ;;
  esac
  [ "${#d}" = 64 ] \
    || die "$where entries are full sha256 digests — 64 hex characters, not ${#d}"
  SCAN_ALLOW_DIGESTS+=("$(printf '%s' "$d" | tr 'A-F' 'a-f')")
  # Kept beside the digest so the excusal can say WHERE the exception came from
  # and, for the file form, what its line called the package. The log is the
  # only artifact a reviewer has after the runner is gone; one that names
  # neither is an audit trail back to a hash.
  SCAN_ALLOW_WHERE+=("$where")
}

# The same digests, from a file, because past a handful the variable stops being
# reviewable. A YAML scalar cannot carry a comment per line, and a bare list of
# 71 hashes is one nobody reads — which is how an allowlist becomes the hole it
# was meant to close. The file gives every digest a line of its own and a name
# beside it.
#
# The name is REQUIRED, not encouraged: a digest with no comment is refused. The
# rule everywhere else in this layer is that a fixture is excused by the package
# that ships it and never by the hash alone, and this is the one place that rule
# can actually be enforced rather than written down.
#
# Parsed here, at the top, BEFORE the prepare command runs. The build job's
# checkout is writable by the install it is about to run, so an allowlist read
# after third-party code executed would be one that code could have extended.
if [ -n "${CACHE_SCAN_ALLOW_FILE:-}" ]; then
  [ -f "$CACHE_SCAN_ALLOW_FILE" ] \
    || die "CACHE_SCAN_ALLOW_FILE names no readable file: $(safe_path "$CACHE_SCAN_ALLOW_FILE") — an allowlist that is not there excuses nothing and reads exactly like one that worked"
  scan_allow_lineno=0
  while IFS= read -r scan_allow_line || [ -n "$scan_allow_line" ]; do
    scan_allow_lineno=$((scan_allow_lineno + 1))
    # A whole-line comment or a blank line is structure, not an entry.
    #
    # Strip the leading whitespace and judge what is left, rather than trying to
    # spell "optional indentation then `#`" as a glob. `[ \t]*'#'*` reads like
    # that and is not: the bracket matches exactly ONE character and the `*`
    # matches anything, so every indented line holding a `#` anywhere — an
    # entry that an editor auto-indented, or one pasted out of the docs — was
    # skipped as a comment. Silently: the digest simply never loaded, and the
    # operator then watches the scan refuse a fixture they can see in the file.
    scan_allow_bare=${scan_allow_line#"${scan_allow_line%%[![:space:]]*}"}
    case "$scan_allow_bare" in
      '' | '#'* ) continue ;;
    esac
    scan_allow_digest=${scan_allow_line%%#*}
    # Nothing before the `#`, or no `#` at all: either way there is a digest
    # standing on its own authority.
    [ "$scan_allow_digest" != "$scan_allow_line" ] \
      || die "CACHE_SCAN_ALLOW_FILE line $scan_allow_lineno excuses a digest with no comment naming the package that ships it — a hash on its own is one nobody can review: $(safe_path "$scan_allow_line")"
    # Trailing `#` with nothing after it is a comment marker, not a name.
    scan_allow_name=$(printf '%s' "${scan_allow_line#*#}" | tr -d '[:space:]')
    scan_allow_label=$(printf '%s' "${scan_allow_line#*#}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$scan_allow_name" ] \
      || die "CACHE_SCAN_ALLOW_FILE line $scan_allow_lineno has an empty comment — name the package that ships the file"
    scan_allow_digest=$(printf '%s' "$scan_allow_digest" | tr -d '[:space:]')
    [ -n "$scan_allow_digest" ] \
      || die "CACHE_SCAN_ALLOW_FILE line $scan_allow_lineno has a comment but no digest: $(safe_path "$scan_allow_line")"
    # The line's own words go into the audit trail. safe_path, because this is
    # a file on disk and the refusal it may end up in is printed by the job that
    # holds the publishing credential.
    scan_allow_where="CACHE_SCAN_ALLOW_FILE line $scan_allow_lineno ($(safe_path "$scan_allow_label"))"
    scan_allow_add "$scan_allow_digest" "$scan_allow_where"
  done <"$CACHE_SCAN_ALLOW_FILE"
  scan_allow_count=${#SCAN_ALLOW_DIGESTS[@]}
  [ "$scan_allow_count" -gt 0 ] \
    || die "CACHE_SCAN_ALLOW_FILE is set but $(safe_path "$CACHE_SCAN_ALLOW_FILE") holds no digests — a file of nothing but comments is not an allowlist"
  command -v sha256sum >/dev/null 2>&1 \
    || die "CACHE_SCAN_ALLOW_FILE is set but sha256sum is not on PATH — the allowlist cannot be evaluated"
  log "the content scan may excuse $scan_allow_count digest(s) named in $(safe_path "$CACHE_SCAN_ALLOW_FILE")"
fi

if [ -n "${CACHE_SCAN_ALLOW_DIGESTS:-}" ]; then
  # read -ra rather than unquoted expansion: the latter globs, and a digest is
  # attacker-adjacent input that should never reach pathname expansion.
  # -d '' as well as IFS: plain `read` stops at the first NEWLINE whatever IFS
  # says, so a YAML block scalar holding three digests would parse one and drop
  # two — unvalidated, unreported, and reading exactly like a list that worked.
  IFS=$', \n\t' read -rd '' -a SCAN_ALLOW_RAW <<<"$CACHE_SCAN_ALLOW_DIGESTS" || true
  for d in ${SCAN_ALLOW_RAW[@]+"${SCAN_ALLOW_RAW[@]}"}; do
    [ -n "$d" ] || continue
    scan_allow_add "$d" CACHE_SCAN_ALLOW_DIGESTS
  done
  # A digest nobody can compute is a digest that excuses nothing, silently.
  command -v sha256sum >/dev/null 2>&1 \
    || die "CACHE_SCAN_ALLOW_DIGESTS is set but sha256sum is not on PATH — the allowlist cannot be evaluated"
fi

SCAN_ALLOW_MATCHED_WHERE=""
scan_digest_is_allowed() { # <sha256>
  local i=0 d
  SCAN_ALLOW_MATCHED_WHERE=""
  for d in ${SCAN_ALLOW_DIGESTS[@]+"${SCAN_ALLOW_DIGESTS[@]}"}; do
    if [ "$d" = "$1" ]; then
      SCAN_ALLOW_MATCHED_WHERE=${SCAN_ALLOW_WHERE[$i]}
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# WHERE a digest was written, not just that it was. The two routes are not
# equally reviewable: `CACHE_SCAN_ALLOW_FILE` forces a comment naming the package
# that ships each fixture and fails the run without one, while
# `CACHE_SCAN_ALLOW_DIGESTS` enforces nothing but hex — forty characters in a
# workflow env block with nothing saying what they excuse.
#
# For a PEM fixture that difference is tolerable. For `url-embedded-basic-auth`
# it is not: that is the class most likely to be a LIVE credential if an operator
# misclassifies one, and it is also the class with a forty-file false-positive
# floor, so it is the one an operator is most likely to excuse in bulk while
# tired. A bare hash cannot be reviewed, and a reviewer cannot tell a `got`
# README from a real connection string by its sha256.
#
# So this narrows, and only in one direction: that label may be excused, but only
# from the file, where the entry has to name what it is. Nothing that was
# excusable by a named, commented entry stops being excusable.
SCAN_FILE_ONLY_LABELS='url-embedded-basic-auth'
scan_excusal_source_is_allowed() { # <labels>
  local label
  for label in $1; do
    # One line, and deliberately not the same shape as the printable-label walk
    # above: two identical `*" $label "* ) ;;` lines would make every mutation
    # aimed at one of them silently hit both, and a mutation that changes two
    # rules proves neither.
    case " $SCAN_FILE_ONLY_LABELS " in *" $label "* ) ;; * ) continue ;; esac
    case "$SCAN_ALLOW_MATCHED_WHERE" in
      "CACHE_SCAN_ALLOW_FILE"* ) ;;
      * )
        log "the content scan will not excuse a $label hit from $SCAN_ALLOW_MATCHED_WHERE — that class needs an entry in the file CACHE_SCAN_ALLOW_FILE names, where the comment says which package ships it"
        return 1 ;;
    esac
  done
  # Explicit, because a `for` whose body ended on a `continue` carries the status
  # of whatever ran last, and this function's answer is "yes" by default.
  return 0
}

# --- the scan --------------------------------------------------------------------
#
# The content patterns of the embedded-credential pass, each with the name its
# failure reports. ONE list, used both to find a hit and to explain it: a second
# copy would be a second thing that has to agree, which is the whole failure mode
# this script's duplicated-but-selftested rules exist to avoid.
#
# The URL schemes a `user:pass@` may follow. ONE definition, used to FIND the hit
# and to validate the scheme the refusal prints, for the same reason the pattern
# list itself is one list.
#
# The anchor is not cosmetic. Unanchored, `://[^/@ "]+:[^/@ "]+@` matches any 5
# bytes in that shape, and since the pass reads binary files too (it must — see
# the grep below) a dependency cache full of gzip and nupkg blobs trips it by
# chance: measured over 4 GiB of random bytes, about three times. Those hits are
# unexcusable by design and land on a hash-named compressed blob, so the operator
# has no move left except deleting the rule — which is how a scan stops being a
# bound. Requiring a real scheme costs the rule nothing, because embedded basic
# auth is BY DEFINITION preceded by one.
#
# The VCS branch is `(git|hg|bzr|svn)(\+(ssh|https?|file))?` and not a hand-listed
# few: pip and npm both accept VCS-pinned dependencies over plain http, so
# `git+https` being on the list while `git+http` was not was an oversight, not a
# policy. Widening it costs the false-positive rate nothing — every branch is
# still a literal scheme followed by `://`.
URL_SCHEME_ALT='https?|ftps?|sftp|ssh|(git|hg|bzr|svn)(\+(ssh|https?|file))?|mongodb(\+srv)?|postgres(ql)?|mysql|mariadb|rediss?|amqps?|s3|gs|ldaps?|smtps?|imap'

# `_authToken` matches an ASSIGNMENT, not a word, and both halves of that were
# paid for on a real tree. This rule can never be allowlisted past, so a false
# positive in it lands on a hash-named store object with no way out, and the
# operator's only remaining move is deleting the rule that guards the one
# credential nothing may excuse. Twice now a bare substring has produced
# exactly that:
#
#   `"authToken": "my_authToken"` — four doc comments in a 456 KB `googleapis`
#   `.d.ts`. The token is the TAIL of a longer identifier, which the left
#   boundary drops.
#
#   `this._authToken = _authToken` — eight files in `neo4j-driver`, which names
#   a private field exactly `_authToken`. No word boundary helps here: the
#   identifier IS the string. What separates it from a credential is that a
#   field is read (`._authToken;`) or bound as a parameter (`(_authToken)`),
#   while a credential is always assigned a value.
#
# So the rule is `_authToken` GIVEN A VALUE: followed by `=` or `:` through
# optional quotes and space, or by the quote-space-quote of yarn v1's
# `"…:_authToken" "token"`, which separates key from value by juxtaposition
# rather than by an operator. It must also not be preceded by `.`, `$` or an
# alphanumeric. The right half rejects the field read and the parameter; the
# left half rejects the property access `._authToken =`, which IS an assignment
# and would otherwise pass, and `$_authToken =`, which a minifier can emit.
# Every form a tool actually writes still matches, and each is a case in the
# suite: `//registry.example.com/:_authToken=…` in an `.npmrc`, indented, with
# spaces or tabs around the `=`, commented out with `;`, quoted as a JSON key
# in `npm config ls --json`, assigned `${NPM_TOKEN}`, npm's environment form
# `npm_config__authToken=…`, and yarn's juxtaposed pair.
#
# `_` is deliberately NOT in the left class. Excluding it would cost
# `npm_config__authToken=` and buy nothing: neither false positive above needs
# it, since `.` alone rejects the property access.
#
# What is still given up is a key spelled with a dot — `registry.example.com._authToken=`
# — which nothing writes; npm, pnpm and yarn all use `//host/path/:_authToken`.
# The dot is the one class member the neo4j evidence actually requires, so that
# is the trade, stated rather than glossed.
#
# A bracket expression is why EVERY grep that runs these patterns pins
# `LC_ALL=C`, and that is not tidiness: with GNU grep on glibc in a UTF-8
# locale `[^A-Za-z0-9]` matches a CHARACTER, so a byte that is not valid UTF-8
# in front of the token makes the whole rule miss. The boundary is free under
# the byte locale and a hole without it. Two of those greps decide whether a
# file is refused; the three in `explain_credential_hit` only decide what the
# refusal prints, and an unpinned one there means the gate refuses a file and
# then cannot say which rule caught it — on exactly the bytes this boundary was
# written for.
CREDENTIAL_PATTERNS=(
  "registry-auth-token|(^|[^A-Za-z0-9.\$])_authToken([[:space:]\"']*[=:]|[\"'][[:space:]]+[\"'])"
  "url-embedded-basic-auth|(^|[^A-Za-z0-9+.-])($URL_SCHEME_ALT)://[^/@[:space:]\"]+:[^/@[:space:]\"]+@"
  "private-key-header|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)

# Says what the content pass actually caught. It needs saying because the pass
# finds a FILE, and in a dependency cache a file's name is a content hash —
# `.../pnpm-store/v3/files/72/93a11b…e02` names nothing anyone can act on, so the
# refusal reads identically whether it caught a leaked registry token or a
# package's test fixture. A fail-closed gate nobody can read is one that gets
# deleted the second time it fires.
#
# It prints WHERE and WHICH, never WHAT: the matched text is a candidate secret,
# and a CI log is readable by everyone who can see the run, so echoing it there
# would publish the very thing the gate exists to contain. Counts, line numbers
# and a URL scheme are not the secret; the value on that line is, and it stays in
# the file. Whoever investigates re-runs the install and looks locally.
# Which rules a file trips, space-separated. Two callers need this: the reporter
# below, and the allowlist, which excuses some labels and never others.
# EVERY label, never the first: a file is excusable only when every rule it trips
# is an excusable one, so a file holding a token AND a key header must
# come back with both or it becomes excusable. And a grep that ERRORS must not
# read as "did not match" — a dropped label is the direction that makes a file
# excusable, so an error refuses. (`die` inside a command substitution exits only
# that subshell, which yields an empty label string: no match, no excusal, and
# the caller refuses. Fail-closed either way.)
matched_labels() { # <file>
  local file="$1" entry rc out=""
  for entry in "${CREDENTIAL_PATTERNS[@]}"; do
    rc=0
    # LC_ALL=C, for the reason spelled out at the bulk grep in `scan_or_die`:
    # a bracket expression is character-wise in a UTF-8 locale, so an invalid
    # byte in front of a pattern makes it match nothing. Both greps or neither
    # — this one decides which labels a file trips, and a label dropped here is
    # a file that becomes excusable.
    LC_ALL=C grep -qa -E -e "${entry#*|}" "$file" 2>/dev/null || rc=$?
    [ "$rc" -le 1 ] \
      || die "the content scan could not test $(safe_path "$file") against ${entry%%|*} (grep exited $rc)"
    if [ "$rc" = 0 ]; then out="$out ${entry%%|*}"; fi
  done
  printf '%s' "${out# }"
}

# CONFIRMATION, NOT WIDENING. `private-key-header` matches the string
# `-----BEGIN … PRIVATE KEY-----`, and a source file that MENTIONS that string
# is not a file that holds a key. Measured on one real dependency tree: 71 store
# objects trip the rule, 49 are `ssh2`'s published key fixtures and the other 22
# hold no key material at all — `jose`'s importer, `oracledb`'s util, `mongodb`'s
# crypto callbacks, `googleapis`' generated `.d.ts`, `gtoken`'s README. Each one
# has to be excused by digest, and a digest changes on every dependency bump.
# The publish runs unattended at 03:17 UTC; the morning after a routine upgrade
# it goes red, nothing else reports it, and the fleet quietly drifts back to cold
# starts. A gate whose false positives churn is a gate that gets rubber-stamped.
#
# So the pattern stays exactly as it is and stays the cheap prefilter — this asks
# the second question, only of the files it flagged: is there an actual PEM block
# here? A BEGIN line, at least one line of base64 body, and a matching END. That
# still catches all 49 real fixtures and drops all 22 churning ones, and it
# narrows nothing about what a real key looks like.
#
# Fail-closed in both directions that matter. An awk that ERRORS is not "no
# block" — it refuses, like every other probe in this pass. NULs are stripped
# first because the tree holds compressed blobs and the bulk grep reads them with
# `-a`; awk's line handling around a NUL is not something to bet a credential
# gate on. And there is deliberately NO early exit: awk reads to EOF and reports
# in END, because `exit` mid-stream would SIGPIPE `tr` and, under `pipefail`,
# turn a confirmed key into a scan error.
#
# `Proc-Type:` / `DEK-Info:` header lines AND the blank line after them are
# allowed between BEGIN and body, because that is the exact shape an encrypted
# OpenSSL key has; without both, an encrypted key reads as unconfirmed and walks
# straight out to every host in the pool. A blank line buys nothing on its own —
# `body` still has to reach one — so BEGIN followed by END stays unconfirmed.
#
# Leading whitespace is allowed on the header and body lines, because the BEGIN
# and END lines never required it to be absent and a key does not stop being a
# key for being indented. The shape that matters is a YAML block scalar — a
# `key: |` followed by an indented PEM is how every one of these deployment
# formats carries a private key, and YAML strips the common indentation before
# the consumer ever sees it, so that file holds a usable key by any definition
# an attacker cares about. Anchored at column zero, the body lines missed, the
# block aborted, and the file went out as an unconfirmed hit. This widens the
# rule towards CONFIRMING, which is the fail-closed direction: the cost of a
# wrong confirmation is a digest someone has to name in a reviewed diff.
scan_file_holds_pem_block() { # <file>
  local pipes reader parser
  # The reader's status is captured SEPARATELY, and that is the whole point of
  # the if/else. Under `pipefail` a `tr` that could not open the file and an awk
  # that reached END with no key both leave 1, and those are opposite verdicts:
  # the second is a clean file, the first is a file that changed under us between
  # the bulk grep and this confirmation — which is exactly the move an escaped
  # prepare process would make to put a credential back before the pack. Reading
  # PIPESTATUS in the branch body is the only place it is still the pipeline's:
  # any other command, an assignment included, overwrites it.
  if LC_ALL=C tr -d '\000' <"$1" | LC_ALL=C awk '
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/ { inblock = 1; body = 0; next }
    inblock && /-----END [A-Z ]*PRIVATE KEY-----/ {
      if (body > 0) found = 1
      inblock = 0
      next
    }
    inblock && /^[[:space:]]*[A-Za-z][A-Za-z0-9-]*:/ { next }
    inblock && /^[[:space:]]*$/ { next }
    inblock && /^[[:space:]]*[A-Za-z0-9+\/=]+[[:space:]]*$/ { body++; next }
    inblock { inblock = 0 }
    END { exit(found ? 0 : 1) }
  '; then
    pipes="${PIPESTATUS[*]}"
  else
    pipes="${PIPESTATUS[*]}"
  fi
  reader=${pipes%% *}
  parser=${pipes##* }
  [ "$reader" = 0 ] \
    || die "the content scan could not READ $(safe_path "$1") to confirm whether it holds a key block (tr exited $reader) — a file that cannot be read is not a file without a key in it"
  [ "$parser" -le 1 ] \
    || die "the content scan could not confirm whether $(safe_path "$1") holds a key block (exit $parser)"
  [ "$parser" = 0 ]
}

# Whether a digest may excuse this file at all, asked before any digest is
# computed. Three rules match; two of them are excusable and one never is.
#
# `registry-auth-token` is absolute. An `_authToken` line in the cache is the
# attack this whole pass exists for, and no dependency ships one as a fixture,
# so there is nothing to trade off — an operator must not be able to allowlist
# their way past a live registry credential. Being absolute is what obliges the
# pattern to be exact rather than generous: a rule with no escape hatch turns
# every false positive into a demand to delete it, which is why the boundary on
# `_authToken` above is part of this decision and not a tidy-up.
#
# `url-embedded-basic-auth` used to be absolute too, and that was wrong in a way
# only the fleet's first real tree showed. A `user:password@` URL is what a
# package's README, its `.d.ts` and its URL-parser tests are FULL of: measured on
# one monorepo, 40 store objects trip it and every one is a published
# placeholder — `got`'s readme, `@types/node`'s `url.d.ts`, `zod`'s parser tests,
# `pg-pool`'s connection-string example. An unexcusable rule with a 40-file false
# -positive floor does not get respected; it gets deleted, and then nothing
# watches for the real thing. So it is excusable on the same terms as a PEM
# fixture: by digest, named, in a diff someone reviewed.
#
# The floor is per-label, and the two labels get different numbers because the
# thing that makes a digest safe is ENTROPY, not size, and only one of them has
# any. An allowlist entry is itself a published hash — it is checked into the
# repository — so the question for both is the same: given everything already
# known about the file, does its sha256 narrow the secret?
#
#   private-key-header, floor 0. The bytes under that header are key material.
#   Even a 230-byte ed25519 fixture has more entropy in it than an attacker can
#   walk, so its digest tells them nothing they can use. Excusable at any size,
#   which is what keeps `ssh2`'s smaller fixtures excusable at all.
#
#   url-embedded-basic-auth, floor 1024. Here the carrier is usually PUBLIC — a
#   README, a `.d.ts`, a parser test, all of them in a tarball on npm — so the
#   only unknown in the preimage is the credential itself. A 47-byte
#   `mongodb://user:pass@host` is worse still: the refusal already prints byte
#   count, line count, match line and scheme, which pins it to one field. Below
#   the floor the hash is an offline oracle with no rate limit, so the entry
#   that would excuse it is one nobody may write down.
SCAN_EXCUSABLE_MIN_BYTES=1024
# The floor for one label, or a refusal. The default arm is what makes this a
# whitelist rather than "anything but the token rule": a rule added to the scan
# later is unexcusable until someone gives it a number here, in a diff.
scan_label_min_bytes() { # <label>
  case "$1" in
    private-key-header ) printf '0' ;;
    url-embedded-basic-auth ) printf '%s' "$SCAN_EXCUSABLE_MIN_BYTES" ;;
    * ) return 1 ;;
  esac
}

# Whether a digest may excuse this file at all, asked before any digest is
# computed. EVERY label the file trips must be excusable at that file's size: a
# README documenting both a registry token and a connection string is a file no
# list may excuse, however innocent either half looks alone.
scan_hit_is_excusable() { # <file>
  local labels label floor size
  labels=$(matched_labels "$1")
  # No label means the grep failed inside a subshell, not that the file is
  # clean — this is only ever called on a file the scan already matched. The
  # call sites are all `if` conditions, which switches `set -e` off for this
  # whole body, so without this an errored grep would walk the empty loop and
  # fall through to a size test that any real file passes.
  [ -n "$labels" ] || return 1
  size=$(wc -c <"$1") || return 1
  for label in $labels; do
    floor=$(scan_label_min_bytes "$label") || return 1
    [ "$size" -ge "$floor" ] || return 1
  done
}

# Whether the REFUSAL may print this file's digest — a strictly narrower question
# than whether a list may excuse it, and the diff that fused the two was wrong.
# Excusing costs an operator a reviewed line naming the package; printing costs
# nothing and reaches everyone who can read the run. So the log offers a digest
# only where the file's own bytes are the secret, which is the private-key case
# and only it. For a URL credential the operator computes the digest off the log
# with CACHE_DRY_RUN=1 — the same route a fixture has always had.
SCAN_PRINTABLE_LABELS='private-key-header'
scan_hit_digest_is_printable() { # <file>
  local labels label
  labels=$(matched_labels "$1")
  [ -n "$labels" ] || return 1
  for label in $labels; do
    case " $SCAN_PRINTABLE_LABELS " in
      *" $label "* ) ;;
      * ) return 1 ;;
    esac
  done
  # Size still matters here for the reason it always did: this rule matches a
  # HEADER, and a 60-byte header in front of a short string is not key material.
  [ "$(wc -c <"$1")" -ge "$SCAN_EXCUSABLE_MIN_BYTES" ]
}

explain_credential_hit() { # <tree> <file>
  local root="$1" file="$2" entry label pat n scheme
  {
    printf 'the embedded-credential pass matched in %s\n' "$(safe_path "${file#"$root"/}")"
    printf '  file: %s bytes, %s line(s)\n' "$(wc -c <"$file")" "$(wc -l <"$file")"
    for entry in "${CREDENTIAL_PATTERNS[@]}"; do
      label="${entry%%|*}" pat="${entry#*|}"
      n=$(LC_ALL=C grep -ca -E -e "$pat" "$file" 2>/dev/null) || n=0
      [ "$n" -gt 0 ] || continue
      printf '  %s: %s match(es), first on line %s\n' \
        "$label" "$n" "$(LC_ALL=C grep -na -m1 -E -e "$pat" "$file" 2>/dev/null | cut -d: -f1)"
      # The one extra fact worth having: the scheme in front of a `user:pass@`
      # tells a real registry credential (`https`) apart from a fixture
      # connection string (`mongodb`, `postgres`, `git+ssh`).
      #
      # Printed ONLY when it is one of these, and that allow-list is the whole
      # safety argument. What sits before `://` is not reliably a scheme word —
      # cache content is raw blobs and concatenated fields, so the maximal run of
      # `[A-Za-z0-9+.-]` there can be an adjacent token or part of the credential
      # itself. Echoing whatever was found would leak exactly the bytes this
      # function exists not to print. Anything unrecognised says so and stops.
      if [ "$label" = url-embedded-basic-auth ]; then
        scheme=$(LC_ALL=C grep -oEa -m1 -e "$pat" "$file" 2>/dev/null | head -n1 \
          | sed -E 's@^[^A-Za-z]*@@; s@://.*@@') || true
        # `grep -c … >/dev/null` and never `grep -qE`: the writer is an in-process
        # `printf` of a shell variable, and the status of this pipeline IS whether
        # the scheme is recognised. `-q` exits on the first match, the `printf`
        # dies of EPIPE, and pipefail then reports a scheme that WAS recognised as
        # one that was not — printing the raw hit the allow-list exists to keep out
        # of the log. See PFR3 in check-pipefail-readers.sh.
        if printf '%s' "$scheme" | grep -cE "^($URL_SCHEME_ALT)$" >/dev/null; then
          printf '    scheme: %s\n' "$scheme"
        else
          printf '    scheme: not a recognised URL scheme — inspect that line locally\n'
        fi
      fi
    done
    printf '  the matched text is deliberately not printed — reproduce the prepare command and inspect that line locally\n'
    # The digest an allowlist entry keys on, so a refusal that turns out to be a
    # package fixture can be excused without anyone having to reproduce the
    # install just to compute it.
    #
    # Three answers, in narrowing order, and the middle one is the point:
    # whether a list MAY excuse this file and whether this log may print its
    # digest are different questions with different answers, and the version of
    # this script that asked one function for both handed out an oracle.
    #
    # One-wayness is not what withholds a digest. Everything above already
    # narrows the preimage hard — exact byte count, line count, match line, URL
    # scheme — and where the rest of the file is a package's published README the
    # only unknown left is the credential. An unsalted sha256 of a nearly-known
    # plaintext is an offline oracle with no rate limit, so printing it here
    # would hand out the very thing this pass just contained.
    if ! command -v sha256sum >/dev/null 2>&1; then
      printf '  no digest is printed: this machine has no sha256sum, so an allowlist entry for this file has to be computed somewhere that does\n'
    elif scan_hit_digest_is_printable "$file"; then
      printf '  sha256: %s\n' "$(sha256sum <"$file" | cut -d' ' -f1)"
      printf '  if this is a dependency fixture and not a leak, put that digest on CACHE_SCAN_ALLOW_DIGESTS -- or, past a handful, in the file CACHE_SCAN_ALLOW_FILE names -- in BOTH jobs\n'
    elif scan_hit_is_excusable "$file"; then
      printf '  a named digest CAN excuse this file, but the log does not print it. A digest is offered only where the secret IS the file -- enough key material that a hash of it is no use to anyone. This file is not that: either its rule matches a header in front of a short string, or the rest of its bytes are a package README anyone can read. Either way the byte count, line count and match line above already narrow the preimage, so compute the digest yourself with CACHE_DRY_RUN=1 and put it in the file CACHE_SCAN_ALLOW_FILE names, in BOTH jobs\n'
    else
      printf '  no digest is printed for this file, and no list will excuse it at this size. A registry token is never excusable; a URL credential is, but only in a file of at least %s bytes, because below that its hash is an oracle for its own contents. Fix the cause instead -- a prepare command that authenticates, or a dependency that has no business being in the tree\n' "$SCAN_EXCUSABLE_MIN_BYTES"
    fi
  } >&2
}

# The pass itself. Everything above decides what a hit MEANS; this walks the
# tree and acts on it.
#
# A filename list only catches a credential a tool wrote to its own config. It
# does not see one INSIDE cache content — npm's _cacache index entries keep
# per-entry request metadata, pip's and uv's HTTP caches keep the request URL,
# and a registry URL with embedded basic auth is a credential in a file whose
# name is a hash. CREDENTIAL_PATTERNS holds the high-confidence ones; broader
# ones (a bare `authorization:`, `"private_key"`) match package test fixtures
# often enough that adding them would train someone to delete the check. This
# pass is a floor, not a guarantee — the guarantee is not authenticating in the
# prepare command at all.
scan_credentials_or_die() { # <tree>
  local root="$1" bad
  # Resolved HERE, not at load time: a caller that sources this file early — the
  # publisher does, so the library is in place before the untrusted prepare
  # command runs — has not created its archive directory yet. A `mktemp -d` at
  # load time would also leave a directory behind on every source that never
  # scans.
  [ -n "${SCAN_TMPDIR:-}" ] || SCAN_TMPDIR="$(mktemp -d)" ||
    die "the content scan could not create its temporary directory"
  [ -d "$SCAN_TMPDIR" ] || die "not a directory: SCAN_TMPDIR=$(safe_path "$SCAN_TMPDIR")"
  local -a pass=()
  local entry digest labels excused=0 unconfirmed=0 seen=0 hits rc=0
  for entry in "${CREDENTIAL_PATTERNS[@]}"; do pass+=(-e "${entry#*|}"); done
  # Listed to a file, and the exit status is checked. grep says 0 for "found",
  # 1 for "nothing", >=2 for "I broke" — and a >=2 that goes unread reads exactly
  # like a clean pass. On a multi-GB tree walked to the end (see below) that is
  # not theoretical: an unreadable path or a killed walk would otherwise publish.
  #
  # `mktemp`, never a fixed name under $SCAN_TMPDIR. The prepare command runs as
  # this uid BEFORE the scan and is handed $STAGE, so it knows the temp root: a
  # predictable name lets it pre-create `content-hits` as a symlink to /dev/null
  # (grep writes nowhere, rc=0, the loop reads nothing) or as a directory (the
  # redirection fails with status 1, indistinguishable from "no hits"). Either
  # one turns the only pass that sees an embedded credential into a no-op, and in
  # the single-phase mode there is no second scan to catch it. O_EXCL on an
  # unguessable name is what closes that.
  hits=$(mktemp "$SCAN_TMPDIR/hits.XXXXXX") || die "the content scan could not create its hit list"
  # `-Z` and `read -d ''`: NUL-separated, because a Linux filename may legally
  # hold a NEWLINE and this list is parsed. With a newline-terminated list, a
  # file named `<excused-fixture>\n` splits into two records — the excused
  # fixture's own path, then an empty line the loop skips — so the file whose
  # name carried the newline is never opened, never digested, and is packed.
  # The allowlist is what makes that fatal: the first record is excused rather
  # than refused, so the pass ends green. NUL is the one byte a path cannot
  # contain, which is why it is the only safe separator here.
  #
  # `-a` and NOT `-I`. `-I` skips a file grep classifies as binary, and grep
  # classifies on the first NUL byte it reads — so the prepare command, which is
  # untrusted third-party install code by this script's own threat model, opts
  # any file out of this pass by writing one leading NUL in front of the
  # credential. It defeats both jobs identically, because the publish job's
  # re-scan of the unpacked archive calls this same function. What `-a` costs is
  # a full read of the tree AND chance matches inside the compressed blobs it now
  # reads — measured at roughly one per gibibyte for a rule as loose as
  # `://x:y@`, on a 4 GiB cache, against files whose names are content hashes and
  # which cannot be excused. That is the reason every pattern above is anchored
  # to something a random byte stream does not produce; it is not a detail of the
  # patterns, it is the condition on which reading binaries is affordable.
  # `LC_ALL=C` for the same reason `-a` is here: the pass reads bytes, not text.
  # In a UTF-8 locale a bracket expression matches one CHARACTER, so a byte in
  # 0x80-0xFF that is not valid UTF-8 is not a character and `[^A-Za-z0-9]`
  # matches nothing in front of it — which turns `\xff_authToken=<token>` into a
  # clean file. That is the leading-NUL trick above with one byte changed, and
  # against the one label no allowlist may excuse. Measured on ubuntu-latest,
  # whose image sets LANG=C.UTF-8: without this, that string is not found.
  LC_ALL=C grep -rlaZ -E "${pass[@]}" "$root" >"$hits" 2>/dev/null || rc=$?
  [ "$rc" -le 1 ] || die "the staged tree could not be scanned for embedded credentials (grep exited $rc)"
  # EVERY hit, not just the first. With an allowlist in play, stopping at the
  # first match would let an excused file stand in front of an unexcused one and
  # take the whole pass green.
  while IFS= read -r -d '' bad; do
    [ -n "$bad" ] || continue
    seen=$((seen + 1))
    # The prefilter's second question, asked before anything else. Only for a
    # file whose ONLY complaint is the key header: one that also trips a token
    # or a URL credential is refused on that, whatever the header turns out to
    # be. An EMPTY label string means `matched_labels` hit an errored grep, and
    # that is not this branch — it falls through and refuses, as it must.
    labels=$(matched_labels "$bad")
    if [ "$labels" = private-key-header ] && ! scan_file_holds_pem_block "$bad"; then
      log "the content scan looked past $(safe_path "${bad#"$root"/}") — it names a PEM header but holds no key block"
      unconfirmed=$((unconfirmed + 1))
      continue
    fi
    if [ "${#SCAN_ALLOW_DIGESTS[@]}" -gt 0 ]; then
      # Asked BEFORE the digest is computed, so a file no list may excuse never
      # gets one — a registry token is refused here whatever is on the list.
      if scan_hit_is_excusable "$bad"; then
        digest=$(sha256sum <"$bad" | cut -d' ' -f1) \
          || die "the content scan could not digest $(safe_path "${bad#"$root"/}")"
        if scan_digest_is_allowed "$digest" && scan_excusal_source_is_allowed "$labels"; then
          # Logged, never silent. An exception nobody sees is one nobody revisits
          # when the package that needed it is gone.
          log "the content scan excused $(safe_path "${bad#"$root"/}") — sha256 $digest, excused by $SCAN_ALLOW_MATCHED_WHERE"
          excused=$((excused + 1))
          continue
        fi
      fi
    fi
    explain_credential_hit "$root" "$bad"
    die "the staged tree holds what looks like an embedded credential ($(safe_path "${bad#"$root"/}")) — refusing to publish it"
  done <"$hits"
  # grep said it found something and the loop saw nothing: the list was truncated
  # or never reached, and the difference between that and a clean tree is the
  # whole pass. Refuse rather than reason about which.
  [ "$rc" != 0 ] || [ "$seen" -gt 0 ] \
    || die "the content scan found matches it could not then read — refusing to publish"
  [ "$excused" = 0 ] || log "the content scan excused $excused file(s) by digest"
  # Counted and reported for the same reason the excusals are: a confirmation
  # stage that quietly drops most of what the prefilter flags is one nobody can
  # tell apart from a prefilter that stopped working.
  [ "$unconfirmed" = 0 ] \
    || log "the content scan looked past $unconfirmed file(s) that name a PEM header but hold no key block"
}

# Run, not sourced: scan the tree named on the command line and say so. The
# Windows build job's only entry point.
#
# $SCAN_INLINE_LIBRARY is the third way in, for a caller that can only hand a
# shell this file's TEXT: `return` at the top level fails there and $SCAN_SOURCED
# says 0 even though nothing is being run standalone. The cache-warmer used to be
# that caller and no longer is — its Cloud Build step stages this file next to
# the publisher, which sources it — so nothing sets the marker today. It
# suppresses only this entry point: the functions
# above are defined either way, and the publisher refuses to continue if
# `scan_credentials_or_die` is somehow not among them.
if [ "$SCAN_SOURCED" = 0 ] && [ "${SCAN_INLINE_LIBRARY:-0}" = 0 ]; then
  [ "$#" = 1 ] || die "usage: scan-cache-credentials.sh <tree>"
  [ -d "$1" ] || die "not a directory: $(safe_path "$1")"
  scan_credentials_or_die "$1"
  log "the content scan found no embedded credential in $(safe_path "$1")"
fi
