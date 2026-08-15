#!/usr/bin/env bash
# ci-runner-infra — the per-lane suite reuse key, as a PURE function.
#
# WHY THIS FILE EXISTS
#
# The merge queue re-checks a pull request when `main` moves under it, and that
# re-check is the queue earning its keep: it is how a semantic conflict between
# two independently-green pull requests is caught. But most merges cannot
# possibly change most pull requests. A documentation merge changes nothing any
# job reads, and today it still costs one full suite per pull request still in
# flight — the single largest source of re-runs that provably cannot change an
# outcome.
#
# So content-address the suite instead of the commit: if the merge-result tree
# presents a lane with byte-identical inputs to a tree whose suite already went
# green, that lane's result is already known.
#
# ONE KEY PER LANE, NOT ONE KEY PER SUITE
#
# A whole-tree key collapses only the trivial case, because every real merge to
# the default branch changes the merge-result tree somewhere. The useful
# question is per lane: a merge that touched `apps/api/**` cannot change the
# verdict of a lane that reads only `apps/web/**`. So the key is computed over
# THAT LANE's declared input paths, and a base move invalidates precisely the
# lanes whose inputs moved.
#
# THE INVARIANT THAT MATTERS
#
# The two failure directions are not symmetric, and neither is this rule. A MISS
# costs one suite. A wrong HIT is a green light over code nobody tested, which
# is strictly worse than paying for the run. So:
#
#   * EVERY lane's key covers the CI-process inputs — the workflows, the
#     composite actions, the gate scripts, the merge-queue config, and the
#     caller-supplied pins (runner image, consumed tag). A workflow or
#     gate-script change alters what "green" MEANS, so no lane may reuse across
#     one. A lane that did would be asserting a result its own definition no
#     longer produces.
#   * The key covers the BASE tree as well as the merge-result tree. Reusing a
#     suite computed against a different base re-introduces exactly the
#     semantic-conflict blindness the merge queue exists to prevent.
#   * Anything doubtful is a MISS: an unreadable line, an undeclared lane, an
#     unknown lane name, a lane with no path filter, a path set that matches
#     nothing, a missing base, a glob outside the supported subset, a missing
#     pin, or any parse error. Same shape as `lane_decision`'s "an empty diff is
#     `full`" — a failed input must never read as "nothing to do".
#   * A cache eviction is the CALLER's miss, never an error. This function never
#     touches a cache; it only says what the key is.
#
# ONE SOURCE OF DECLARED PATHS
#
# The declared paths are read from the same `dorny/paths-filter` configuration
# the lane is already gated on, so a filter fix and a reuse fix are one edit. A
# lane the filter config does not declare — the rollup, the always-on config
# gates — is ALWAYS invalid here and never reuses; there is no second list to
# forget to update.
#
# Pure: no network, no cache, no git invocation, no writes. The caller does the
# git work (`git ls-tree -r`) and hands the result in on stdin, which is also
# what makes every branch of this file testable from fixtures.
#
# Tenancy-agnostic — no customer literals, no repository knowledge. Consumers
# adopt it through the contract in docs/ci-suite-reuse.md.

# The CI-process paths every lane's key covers, whatever that lane declares.
# Additive: a repository whose gate scripts live elsewhere adds them through the
# `%%process` section rather than replacing this list.
_SRK_PROCESS_GLOBS='.github/workflows/**
.github/actions/**
scripts/ci/**
.mergify.yml
.mergify.yaml'

# suite_reuse_key <lane>  — reads the input document (below) on stdin, echoes
#                           "key:<64-hex>" or "miss:<reason>", and exits 0.
#
# The verdict is the OUTPUT, not the exit status, so a `set -e` caller cannot be
# tripped by a miss. A miss is the normal, expected answer.
#
# INPUT DOCUMENT
#
#   %%pins            one opaque line per pinned CI input the tree does not
#                     contain — the runner image reference by digest, the
#                     ci-runner-infra tag this repository consumes. REQUIRED and
#                     must be non-empty: a pin nobody declared is a CI input
#                     nobody covered.
#   %%process         OPTIONAL. Extra CI-process globs, added to the built-in
#                     list above. Never replaces it.
#   %%filters         the `dorny/paths-filter` `filters:` document, verbatim.
#   %%tree-merge      `git ls-tree -r <merge-result-tree>` output.
#   %%tree-base       `git ls-tree -r <base-tree>` output.
#
# Sections may appear in any order. An unknown section is a miss.
suite_reuse_key() {
  local lane="${1:-}"

  case "$lane" in
    '' | *[!A-Za-z0-9_.-]*) echo "miss:lane-name-invalid"; return 0 ;;
  esac

  local section='' line
  local pins='' process='' filters='' tree_merge='' tree_base=''
  local saw_pins=0 saw_process=0 saw_filters=0 saw_merge=0 saw_base=0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      '%%'*)
        section="${line#'%%'}"
        case "$section" in
          pins) saw_pins=1 ;;
          process) saw_process=1 ;;
          filters) saw_filters=1 ;;
          tree-merge) saw_merge=1 ;;
          tree-base) saw_base=1 ;;
          *) echo "miss:unknown-section=$section"; return 0 ;;
        esac
        continue
        ;;
    esac

    if [ -z "$section" ]; then
      [ -n "$line" ] || continue
      # Content before any section header means the caller built the document
      # wrong, and a document built wrong is a document whose sections may also
      # be wrong. Refuse it rather than hashing part of it.
      echo "miss:content-outside-any-section"
      return 0
    fi

    case "$section" in
      # A whitespace-only line is not a pin and not a process path, and letting
      # one through defeats the emptiness checks below: `%%pins` followed by two
      # blank lines made `pins` non-empty, so `miss:pins-empty` did not fire and
      # a key was computed over ZERO declared pins. Every caller emitting that
      # document would agree with every other one — a hit across toolchains that
      # were never compared. Dropped here rather than at the check, so the
      # emptiness questions below stay answerable.
      #
      # Written as `if`, not `test && append`: this function is SOURCED, and a
      # trailing false test would be the loop body's exit status in a caller
      # running `set -e`.
      pins) if [ -n "${line//[[:space:]]/}" ]; then pins+="$line"$'\n'; fi ;;
      process) if [ -n "${line//[[:space:]]/}" ]; then process+="$line"$'\n'; fi ;;
      filters) filters+="$line"$'\n' ;;
      tree-merge) tree_merge+="$line"$'\n' ;;
      tree-base) tree_base+="$line"$'\n' ;;
    esac
  done

  # Presence, then non-emptiness. A section present but empty is the more
  # dangerous of the two: it looks like the caller supplied it.
  [ "$saw_pins" -eq 1 ] || { echo "miss:no-pins-section"; return 0; }
  [ "$saw_filters" -eq 1 ] || { echo "miss:no-filters-section"; return 0; }
  [ "$saw_merge" -eq 1 ] || { echo "miss:no-merge-tree-section"; return 0; }
  # The base is not optional and its absence is not a special case. A key
  # computed without one is a key that reuses across an unknown base.
  [ "$saw_base" -eq 1 ] || { echo "miss:no-base-tree-section"; return 0; }
  [ -n "$pins" ] || { echo "miss:pins-empty"; return 0; }
  [ -n "$tree_merge" ] || { echo "miss:merge-tree-empty"; return 0; }
  [ -n "$tree_base" ] || { echo "miss:base-tree-empty"; return 0; }
  [ "$saw_process" -eq 0 ] || [ -n "$process" ] || { echo "miss:process-section-empty"; return 0; }

  # --- the lane's declared paths, from the filter config it is gated on -------
  local declared rc
  declared=$(_srk_lane_globs "$filters" "$lane")
  rc=$?
  if [ "$rc" -eq 1 ]; then echo "miss:filters-malformed"; return 0; fi
  if [ "$rc" -ne 0 ]; then echo "miss:lane-not-usable=$lane"; return 0; fi

  # --- the effective path set: the lane's own paths PLUS the CI process -------
  local effective="$declared"$'\n'"$_SRK_PROCESS_GLOBS"
  [ -z "$process" ] || effective+=$'\n'"${process%$'\n'}"
  effective=$(printf '%s\n' "$effective" | grep -v '^$' | LC_ALL=C sort -u)

  local g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    _srk_glob_ok "$g" || { echo "miss:glob-unsupported=$g"; return 0; }
  done <<< "$effective"

  # --- normalise both trees --------------------------------------------------
  local norm_merge norm_base
  norm_merge=$(_srk_normalize_tree "$tree_merge") || { echo "miss:merge-tree-malformed"; return 0; }
  norm_base=$(_srk_normalize_tree "$tree_base") || { echo "miss:base-tree-malformed"; return 0; }

  # A lane whose own declared globs match nothing in the merge-result tree is a
  # lane whose filter has drifted from the tree. Its "inputs" are then whatever
  # the drift hid, so its key would be stable across changes it does read.
  local own
  own=$(_srk_select "$norm_merge" "$declared")
  [ -n "$own" ] || { echo "miss:lane-matches-no-path=$lane"; return 0; }

  # Likewise for the CI process: a tree with no workflow, no action and no gate
  # script is not a tree this key can claim to cover.
  local proc_seen
  proc_seen=$(_srk_select "$norm_merge" "$_SRK_PROCESS_GLOBS")
  [ -n "$proc_seen" ] || { echo "miss:no-ci-process-paths-in-tree"; return 0; }

  local d_merge d_base
  d_merge=$(_srk_select "$norm_merge" "$effective" | _srk_hash) \
    || { echo "miss:digest-unavailable"; return 0; }
  d_base=$(_srk_select "$norm_base" "$effective" | _srk_hash) \
    || { echo "miss:digest-unavailable"; return 0; }
  if [ -z "$d_merge" ] || [ -z "$d_base" ]; then
    echo "miss:digest-unavailable"
    return 0
  fi

  # --- the preimage, in this order, and the version prefix that retires it ----
  #
  # `srk1` is not decoration. Any change to what goes into the hash below must
  # bump it, because the alternative is a key that collides with one recorded
  # under the old meaning — a hit against a suite that tested something else.
  local key
  key=$(
    {
      printf 'srk1\n'
      printf 'lane=%s\n' "$lane"
      printf '%s\n' "$effective" | while IFS= read -r g; do
        [ -n "$g" ] && printf 'glob=%s\n' "$g"
      done
      printf '%s' "$pins" | while IFS= read -r g; do
        [ -n "$g" ] && printf 'pin=%s\n' "$g"
      done
      printf 'merge=%s\n' "$d_merge"
      printf 'base=%s\n' "$d_base"
    } | _srk_hash
  ) || { echo "miss:digest-unavailable"; return 0; }
  [ -n "$key" ] || { echo "miss:digest-unavailable"; return 0; }

  echo "key:$key"
  return 0
}

# _srk_lane_globs <filters-yaml> <lane> — echoes one glob per line.
#   rc 0 : usable
#   rc 1 : the document is malformed (nothing about it can be trusted)
#   rc 2 : this lane is not usable — undeclared, declared twice, declared with
#          something this subset cannot read, or declared with no paths at all
#
# The supported subset is deliberately narrow, and everything outside it is rc 2
# rather than a guess. `dorny/paths-filter` accepts YAML anchors, per-change-type
# maps and negations; each of those means the lane reads paths this parser did
# not see, and a lane whose inputs are partly invisible must never reuse.
_srk_lane_globs() {
  local raw="$1" lane="$2"
  local line trimmed name rest indent
  local in_lane=0 seen=0 bad=0 out=''

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in '#'*) continue ;; esac

    indent="${line%%[![:space:]]*}"

    if [ -z "$indent" ]; then
      # Column-zero: a lane header, or nothing this parser understands.
      # The first character and the name charset must agree. They did not: a
      # lane spelled `.ci` is legal under the charset check below and was
      # rejected by this one, which returns 1 — the whole document malformed,
      # so EVERY lane misses over a name only one of them uses. `-` stays out
      # of the leading set deliberately: a column-zero `-` is a list item, not
      # a name.
      case "$trimmed" in
        [A-Za-z0-9_.]*:*) ;;
        *) return 1 ;;
      esac
      name="${trimmed%%:*}"
      # An empty name is not a lane. `:` alone cannot reach here — the leading
      # class excludes it — but `${trimmed%%:*}` is spelled to be read beside
      # the charset test, and a test that cannot state its own empty case is a
      # test somebody widens later without noticing.
      [ -n "$name" ] || return 1
      case "$name" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
      rest="${trimmed#*:}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      rest="${rest%"${rest##*[![:space:]]}"}"

      if [ "$name" = "$lane" ]; then
        seen=$((seen + 1))
        in_lane=1
        if [ -n "$rest" ]; then
          # Scalar shorthand (`web: 'apps/web/**'`). An anchor, an alias or a
          # flow collection is not a path this parser can enumerate.
          # Quoted first: an UNQUOTED leading `*` is a YAML alias, while a
          # quoted one is the ordinary `'**/*.md'` glob. Reading the two the
          # same way is how a lane silently acquires paths it never declared.
          case "$rest" in
            "'"*"'" | '"'*'"') out+="$(_srk_unquote "$rest")"$'\n' ;;
            '&'* | '*'* | '['* | '{'* | '>'* | '|'*) bad=1 ;;
            *) out+="$rest"$'\n' ;;
          esac
        fi
      else
        in_lane=0
      fi
      continue
    fi

    case "$trimmed" in
      '-'*)
        [ "$in_lane" -eq 1 ] || continue
        rest="${trimmed#-}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        rest="${rest%"${rest##*[![:space:]]}"}"
        case "$rest" in
          "'"*"'" | '"'*'"') out+="$(_srk_unquote "$rest")"$'\n' ;;
          '' | '&'* | '*'* | '['* | '{'*) bad=1 ;;
          *) out+="$rest"$'\n' ;;
        esac
        ;;
      *)
        # An indented non-list line is a nested map — `added|modified:`, an
        # anchored block, a per-change-type filter. The lane then reads more
        # than this parser can see.
        [ "$in_lane" -eq 1 ] && bad=1
        ;;
    esac
  done <<< "$raw"

  [ "$bad" -eq 0 ] || return 2
  [ "$seen" -eq 1 ] || return 2
  out="${out%$'\n'}"
  # A lane with no declared paths is the always-on kind — the rollup, the config
  # gates. It is not "everything matched"; it is "nothing was declared", and it
  # never reuses.
  [ -n "$out" ] || return 2

  printf '%s\n' "$out"
  return 0
}

# _srk_unquote <scalar> — strips one layer of matching YAML quotes.
_srk_unquote() {
  local v="$1"
  case "$v" in
    "'"*"'") v="${v#\'}"; v="${v%\'}" ;;
    '"'*'"') v="${v#\"}"; v="${v%\"}" ;;
  esac
  printf '%s' "$v"
}

# _srk_glob_ok <glob> — rc 0 if the glob is inside the supported subset.
#
# Supported: literal segments, `*` inside one segment, and `**` as a WHOLE
# segment. Everything else — `?`, character classes, brace expansion, extglob,
# a leading `!` negation, an absolute or trailing slash — is rejected, because
# a glob this file matches differently from `dorny/paths-filter` is a lane whose
# declared inputs and hashed inputs are two different sets.
_srk_glob_ok() {
  local g="$1" rest seg
  [ -n "$g" ] || return 1
  case "$g" in
    /* | */ | *//*) return 1 ;;
    *[!A-Za-z0-9._/*-]*) return 1 ;;
  esac
  rest="$g"
  while :; do
    seg="${rest%%/*}"
    case "$seg" in
      '**') ;;
      *'**'*) return 1 ;;
    esac
    [ "$seg" != "$rest" ] || break
    rest="${rest#*/}"
  done
  return 0
}

# _srk_normalize_tree <ls-tree-output> — echoes "<oid> <path>" per entry.
# rc 1 on anything it cannot read exactly.
_srk_normalize_tree() {
  local line meta path oid out='' n_in=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    n_in=$((n_in + 1))

    meta="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    [ "$meta" != "$line" ] || return 1

    # `blob` and `commit` (a submodule gitlink) both carry a content identity.
    # A `tree` entry means the caller forgot `-r`, and a partial listing must
    # not be hashed as if it were the whole tree.
    [[ $meta =~ ^[0-7]{6}\ (blob|commit)\ ([0-9a-f]{40,64})$ ]] || return 1
    oid="${BASH_REMATCH[2]}"

    # git quotes paths containing control or non-ASCII bytes. Such a path is
    # readable, but not by this parser, and a path silently dropped is a file
    # silently excluded from the key.
    case "$path" in '' | '"'* | /*) return 1 ;; esac

    out+="$oid $path"$'\n'
  done <<< "$1"

  [ "$n_in" -gt 0 ] || return 1

  # A duplicated path means the listing was concatenated from two trees. Both
  # entries would sort into the digest and the result would look deterministic.
  local n_uniq
  n_uniq=$(printf '%s' "$out" | LC_ALL=C sort -u -k2 | grep -c '' )
  [ "$n_uniq" -eq "$n_in" ] || return 1

  printf '%s' "$out"
  return 0
}

# _srk_select <normalized-tree> <globs> — echoes the matching "<oid> <path>"
# lines, sorted and deduplicated, so the digest is order-independent.
_srk_select() {
  local tree="$1" globs="$2" line path g
  # The globs are read into an array ONCE. A `<<<` inside the per-entry loop
  # writes a temporary file per tree entry, which on a repository-sized tree is
  # thousands of them — this function runs over every file in two trees.
  local -a globv=()
  while IFS= read -r g || [ -n "$g" ]; do
    [ -n "$g" ] && globv+=("$g")
  done <<< "$globs"

  {
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      path="${line#* }"
      for g in "${globv[@]}"; do
        if _srk_match "$g" "$path"; then
          printf '%s\n' "$line"
          break
        fi
      done
    done <<< "$tree"
  } | LC_ALL=C sort -u
}

# _srk_match <glob> <path> — rc 0 on a match. `*` never crosses a `/`; `**`
# matches zero or more whole segments.
_srk_match() {
  local glob="$1" path="$2" pfx

  if [[ $glob != *'*'* ]]; then
    [[ $path == "$glob" ]] && return 0
    return 1
  fi

  # The overwhelmingly common shape (`apps/web/**`), answered without recursion
  # — this runs once per tree entry per glob, on trees with thousands of them.
  if [[ $glob == *'/**' ]]; then
    pfx="${glob%'/**'}"
    if [[ $pfx != *'*'* ]]; then
      [[ $path == "$pfx" ]] && return 0
      [[ $path == "$pfx"/* ]] && return 0
      return 1
    fi
  fi

  _srk_match_seg "$glob" "$path"
}

_srk_match_seg() {
  local g="$1" p="$2" gseg grest pseg prest
  while :; do
    if [ -z "$g" ]; then
      [ -z "$p" ] && return 0
      return 1
    fi

    gseg="${g%%/*}"
    if [ "$gseg" = "$g" ]; then grest=''; else grest="${g#*/}"; fi

    if [ "$gseg" = '**' ]; then
      # zero segments consumed, then one, then two…
      _srk_match_seg "$grest" "$p" && return 0
      while [ -n "$p" ]; do
        if [ "${p%%/*}" = "$p" ]; then p=''; else p="${p#*/}"; fi
        _srk_match_seg "$grest" "$p" && return 0
      done
      return 1
    fi

    [ -n "$p" ] || return 1
    pseg="${p%%/*}"
    if [ "$pseg" = "$p" ]; then prest=''; else prest="${p#*/}"; fi

    # shellcheck disable=SC2053  # gseg IS the pattern here, deliberately.
    [[ $pseg == $gseg ]] || return 1

    g="$grest"
    p="$prest"
  done
}

# _srk_hash — stdin to a lowercase hex sha256. rc 1 if no digest tool exists,
# which is a miss like any other: no hash, no claim.
_srk_hash() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256) || return 1
  else
    return 1
  fi
  out="${out%% *}"
  [ "${#out}" -eq 64 ] || return 1
  printf '%s' "$out"
}
