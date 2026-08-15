# The suite reuse key — published contract

This is the contract consuming repositories adopt. The rule itself is
`scripts/ci/suite-reuse-key.sh`, asserted by
`scripts/ci/suite-reuse-key.selftest.sh` in this repository's CI. It builds on
the lane model in [`ci-lane-model.md`](ci-lane-model.md) — adopt that first, it
is the source of the declared paths this key is computed over — and on the
single-step queue in [`ci-merge-queue-baseline.md`](ci-merge-queue-baseline.md).

---

## What it is

The merge queue re-checks a pull request when the default branch moves under it.
That re-check is the queue earning its keep: it is how a semantic conflict
between two independently-green pull requests is caught, and removing it would
undo the reason the queue exists.

But most merges cannot possibly change most pull requests. A documentation merge
changes nothing any job reads, and it still costs one full suite for every pull
request in flight. A merge confined to one side of the repository cannot change
the verdict of a lane that reads only the other side.

So content-address the suite instead of the commit. For each lane, hash that
lane's declared input paths **in the merge-result tree**. If the resulting key
matches one a green suite already recorded, that lane's result is already known
and the lane reports success without claiming a runner.

**One key per lane, not one key per suite.** A whole-tree key collapses only the
trivial case, because every real merge changes the merge-result tree somewhere.
Per lane, a base move invalidates precisely the lanes whose inputs moved.

| What merged | What it can change | What this key does |
|---|---|---|
| documentation, ADRs, issue templates | nothing a job reads | every lane reuses |
| one side of the app, for a pull request confined to the other | only the lanes whose filters match | the matching lanes re-run, the rest reuse |
| the CI process itself | **everything** — the job definitions are what changed | no lane reuses |

## The invariant

The two failure directions are not symmetric, and neither is the rule:

- A **miss** costs one suite, and shows up in the bill.
- A wrong **hit** is a green light over code nobody tested — strictly worse than
  paying for the run, and indistinguishable from a healthy pull request.

So:

1. **Every lane's key covers the CI process**, whatever that lane declares:
   `.github/workflows/**`, `.github/actions/**`, `scripts/ci/**`, both spellings
   of the queue config (`.mergify.yml` and `.mergify.yaml`) and the
   caller-supplied pins. A workflow or gate-script change alters what
   "green" *means*; a lane that reused across one would be asserting a result
   its own definition no longer produces. This is not an optimisation to be
   relaxed later — it is the reason the gate holds.
2. **The key covers the base tree as well as the merge-result tree.** Reusing a
   suite computed against a different base re-introduces exactly the
   semantic-conflict blindness the queue exists to prevent.
3. **Anything doubtful is a miss**: an unreadable listing, an undeclared lane, an
   unknown lane name, a lane with no path filter, a filter that matches no file,
   a missing base, a missing pin, a glob outside the supported subset, or any
   parse error. Same shape as the lane model's "an empty diff is `full`".
4. **A cache eviction is a miss, never an error.** The function never touches a
   cache; it only says what the key is. The caller must treat a lookup failure
   as "run the suite".
5. **A lane with no path filter never reuses.** The always-on ones — the rollup,
   the configuration gates — are always invalid here by construction.

## What goes into the hash, in order

```
srk1                       ← format version; bump it and every recorded key retires
lane=<lane>
glob=<g>                   ← the effective path set, sorted and deduplicated:
                             the lane's declared globs ∪ the CI-process globs
pin=<line>                 ← each %%pins line, verbatim, in the order given
merge=<sha256>             ← sha256 over the sorted "<oid> <path>" lines of the
                             effective set in the MERGE-RESULT tree
base=<sha256>              ← the same over the BASE tree
```

The whole block is sha256'd; the result is the key. Object ids carry file
content, paths carry renames, so a rename with byte-identical content is a
different key. Listing order is not part of the identity.

`srk1` is not decoration. Any change to what goes into the hash must bump it —
otherwise a new key can collide with one recorded under the old meaning, which
is a hit against a suite that tested something else.

## The input document

`suite_reuse_key <lane>` reads one document on stdin and echoes
`key:<64-hex>` or `miss:<reason>`, exiting 0 either way — the verdict is the
output, not the exit status, so a `set -e` caller cannot be tripped by a miss.

| Section | Required | Contents |
|---|---|---|
| `%%pins` | yes, non-empty | one opaque line per CI input the tree does not contain — the runner image by digest, the `ci-runner-infra` tag consumed |
| `%%process` | no | extra CI-process globs, **added to** the built-in list, never replacing it |
| `%%filters` | yes | the `dorny/paths-filter` `filters:` document, verbatim |
| `%%tree-merge` | yes | `git ls-tree -r` of the merge-result tree |
| `%%tree-base` | yes | `git ls-tree -r` of the base tree |

Sections may appear in any order. An unknown section is a miss.

The declared paths come from the **same filter configuration the lane is already
gated on** — one source of truth, so a filter fix and a reuse fix are one edit.
There is deliberately no second list.

### The supported glob subset

Literal segments, `*` within one segment, and `**` as a whole segment. Anything
else — `?`, character classes, brace expansion, extglob, a leading `!` negation,
YAML anchors or aliases, per-change-type maps (`added|modified:`), flow
sequences — makes the lane invalid and it misses. A glob this rule matches
differently from `dorny/paths-filter` is a lane whose declared inputs and hashed
inputs are two different sets, so it is refused rather than approximated.

---

## Adoption — five steps, in order

### 0. Prerequisite: the lane model, and one aggregate required check

Everything below reports through the aggregate job from
[`ci-lane-model.md`](ci-lane-model.md) requirement 1. Without it, a reused lane
reports `skipped` and dequeues the pull request permanently. Adopt the lane
model first; this key consumes its filter configuration.

### 1. Compute the key in the classifier job, off the pool

```yaml
  reuse:
    name: Reuse key
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      web: ${{ steps.keys.outputs.web }}
      api: ${{ steps.keys.outputs.api }}
    steps:
      - uses: actions/checkout@<40-char-commit-sha> # v4
        with:
          # Same reasoning as the lane classifier: the merge-result tree is
          # HEAD and the base tree is HEAD^1, so exactly two commits are
          # needed. `fetch-depth: 0` here is a full clone paid to list a tree.
          fetch-depth: 2
      - id: keys
        run: |
          set -euo pipefail
          # Pinned to an immutable commit, NOT a tag. This shell is downloaded
          # and SOURCED inside a checked-out CI job; a moved or recreated tag
          # would change what every consuming repository considers "already
          # tested", with no pull request in any of them. The digest check is
          # what makes the pin worth anything.
          sha=<40-char-commit-sha>
          curl -fsSL -o /tmp/suite-reuse-key.sh \
            "https://raw.githubusercontent.com/<org>/ci-runner-infra/$sha/scripts/ci/suite-reuse-key.sh"
          echo "<sha256>  /tmp/suite-reuse-key.sh" | sha256sum -c -
          # shellcheck source=/dev/null
          source /tmp/suite-reuse-key.sh

          {
            echo '%%pins'
            # Every CI input that is not a file in this tree. Under-declaring
            # here is the one way to get a wrong hit that no test can see.
            echo "runner-image=${{ vars.CI_RUNNER_IMAGE_DIGEST }}"
            echo "ci-runner-infra=$sha"
            echo '%%filters'
            cat .github/paths-filter.yml
            echo '%%tree-merge'
            git ls-tree -r HEAD
            echo '%%tree-base'
            git ls-tree -r HEAD^1
          } > /tmp/srk-input

          for lane in web api; do
            verdict=$(suite_reuse_key "$lane" < /tmp/srk-input)
            echo "::notice::reuse $lane $verdict"
            case "$verdict" in
              key:*) echo "$lane=${verdict#key:}" >> "$GITHUB_OUTPUT" ;;
              *)     echo "$lane=" >> "$GITHUB_OUTPUT" ;;
            esac
          done
```

Keep the filter document in **one file** that both `dorny/paths-filter` and this
step read:

```yaml
      - uses: dorny/paths-filter@<40-char-commit-sha> # v3
        id: changes
        with:
          filters: .github/paths-filter.yml
```

### 2. Look the key up — an exact match, and only an exact match

```yaml
  web:
    needs: [lane, reuse]
    if: needs.lane.outputs.lane != 'none'
    runs-on: ubuntu-latest
    outputs:
      reused: ${{ steps.lookup.outputs.cache-hit }}
    steps:
      - id: lookup
        # An empty key means the function said MISS; `lookup-only` never
        # restores anything, it only asks whether the record exists.
        if: needs.reuse.outputs.web != ''
        continue-on-error: true
        uses: actions/cache/restore@<40-char-commit-sha> # v4
        with:
          path: .srk
          key: srk1-web-${{ needs.reuse.outputs.web }}
          lookup-only: true
          # NO `restore-keys`. Prefix matching would hit on a DIFFERENT key,
          # which is the one outcome this whole contract exists to prevent.
```

`continue-on-error: true` is what makes an eviction, an outage or a throttled
cache service a miss rather than a red check.

### 3. Run the lane only on a miss, and record only on green

```yaml
      - name: heavy work
        if: steps.lookup.outputs.cache-hit != 'true'
        run: ./run-the-lane.sh

      # Recorded AFTER the work passed, and only then. A key recorded before the
      # result is known is a promise the suite has not kept.
      - name: record the green suite
        if: steps.lookup.outputs.cache-hit != 'true'
        uses: actions/cache/save@<40-char-commit-sha> # v4
        with:
          path: .srk
          key: srk1-web-${{ needs.reuse.outputs.web }}
```

### 4. Say what was inherited

```yaml
      - name: report
        if: steps.lookup.outputs.cache-hit == 'true'
        run: echo "::notice::lane web reused key ${{ needs.reuse.outputs.web }}"
```

A reused lane that does not say so is a lane nobody can audit after the fact.
The aggregate check still runs and still reports for the pull request — reuse
skips the *work*, never the *reporting*.

### 5. Know where the record is visible from

GitHub Actions cache scoping is not repository-wide. A record written by a run
on one branch is readable by later runs **on that branch** and by runs on
branches created from it; a record written on the default branch is readable
everywhere. Practically:

- **Same branch, re-checked after a base move** — the case the single-step queue
  produces, and the largest share of redundant re-checks — hits. This is the
  saving.
- **Across two unrelated pull requests** — does not hit, by design of the cache,
  unless the record was written on the default branch.

Do not work around this by widening the key's scope. A store with wider
visibility (a check-run annotation, an artifact registry) may be substituted;
the key is unchanged, and the invariants above still apply to it.

---

## What a consuming repository must not do

- **Do not vendor the rule.** Reference it by pinned commit with a digest check.
  Nine divergent copies of the pool module is the mistake this repository was
  created to undo.
- **Do not add a second source of declared paths.** The key reads the same
  `dorny/paths-filter` document the lane is gated on. A separate reuse list
  drifts, and it drifts silently in the direction of a wrong hit.
- **Do not trim the CI-process globs to get more hits.** A lane that reuses
  across a workflow, action, gate-script, merge-queue-config or pin change is
  reporting a result its current definition never produced.
- **Do not leave a CI input out of `%%pins`.** The runner image and the consumed
  `ci-runner-infra` commit are inputs that no tree listing contains. An
  undeclared one is a wrong hit that no test in either repository can see.
- **Do not use `restore-keys`.** Prefix matching turns "the same key" into
  "something that starts the same way".
- **Do not record the key before the suite is green**, and never record one for a
  lane that was reused rather than run.
- **Do not treat a lookup failure as an error.** Eviction, throttling and a cold
  cache are all misses. `continue-on-error: true` on the lookup step.
- **Do not give a reuse key to a lane with no path filter.** The rollup and the
  always-on configuration gates run every time; that is what they are for.
- **Do not skip the aggregate check on a hit.** A `skipped` required check
  dequeues the pull request permanently — see the stale-`skipped` trap in
  [`ci-lane-model.md`](ci-lane-model.md).
