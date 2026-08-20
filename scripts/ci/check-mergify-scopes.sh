#!/usr/bin/env bash
# =============================================================================
# check-mergify-scopes.sh — the scope map covers the repository, exhaustively
#
# USAGE
#   bash scripts/ci/check-mergify-scopes.sh            # the gate
#   bash scripts/ci/check-mergify-scopes.sh --selftest # fixtures, run first
#   bash scripts/ci/check-mergify-scopes.sh --fanout   # the barrier evidence
#
# WHY THIS EXISTS
#   Under `merge_queue.mode: parallel`, Mergify groups queued pull requests by
#   their EXACT set of scopes and tests groups that share no scope AT THE SAME
#   TIME, with no dependency between them. (Under `serial` this gate's coverage
#   check is deliberately inert, so a repository can carry it BEFORE the width
#   rises rather than in the pull request that makes it matter.)
#
#   The failure mode that creates is silent and points the wrong way. A pull
#   request whose files match NO scope carries the EMPTY scope set. An empty set
#   overlaps nothing, so such a pull request runs concurrently with every other
#   entry in the queue — unscoped is the MOST parallel state, not the safest
#   one. Nothing in Mergify reports it: the queue stays green, the dashboard
#   shows the scopes that were declared, and the uncovered half of the repo
#   quietly stops being serialised against anything.
#
#   Before this gate existed (2026-08-19) that half was most of the repository:
#   21 of 34 directories under apps/ and 62 of 68 under packages/ matched no
#   scope, because the scope block had been written on 2026-08-17 as a BATCHING
#   PREFERENCE, where partial coverage is merely a partial optimisation. Under
#   parallel mode the same file is a correctness statement, and a partial one is
#   wrong rather than incomplete.
#
#   So: every workspace package must be named by a scope or by a barrier, and
#   adding a package must fail the build until somebody decides which.
#
# WHAT IT DOES NOT DO
#   It does not judge whether two scopes are genuinely independent — no gate
#   can. It asserts coverage, barrier sanity and capacity arithmetic, which are
#   the three things that are decidable from the file plus the workspace graph.
#
# THE PARSER IS A HARD DEPENDENCY, for the same reason as in
# check-merge-queue-single-step.sh: a key one level too deep is not a value in
# an odd spot, it is a file Mergify REFUSES TO LOAD, and a keyword scan finds
# the value it hoped for and reports a covered repository over a queue that
# cannot start. python3 + PyYAML is expected on the runner image; the gate
# installs nothing, because a required check that pip-installs an unpinned
# package puts every merge behind PyPI on a host holding a service identity.
# =============================================================================
set -euo pipefail

# WHERE THE REPOSITORY ROOT IS, ASKED RATHER THAN COUNTED. Guessing `../..` from
# the script's own location assumes every repository vendors this at
# `scripts/ci/`, and Borsh-Tablet-App keeps its gates in `ci/` — there the guess
# lands one directory ABOVE the checkout, the config is not found, and the gate
# fails with a path error rather than an answer. Ask git, and keep the guess as
# the fallback for a tarball or a submodule with no work tree.
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ] || [ ! -f "$REPO_ROOT/.mergify.yml" ]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# Pick an interpreter that can actually import yaml. `actions/setup-python`
# prepends a Python that does not carry the image's python3-yaml, so a workflow
# that set up Python for an unrelated step would otherwise turn this gate into
# "no YAML parser available" on a runner that has one.
PY=""
for cand in python3 python /usr/bin/python3; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import yaml' >/dev/null 2>&1; then
    PY="$cand"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "check-mergify-scopes: no python3 with PyYAML available" >&2
  exit 1
fi

run_reader() { "$PY" - "$@" <<'PYEOF'
import fnmatch
import json
import os
import re
import sys

mode = sys.argv[1]
root = sys.argv[2]
cfg_path = os.path.join(root, '.mergify.yml')

import yaml

errors = []
checks = []


def fail(check_id, msg):
    errors.append(check_id)
    print("FAIL [%s] %s" % (check_id, msg))


# --- the workspace graph -----------------------------------------------------
def workspace_packages(root):
    """Every directory holding a named package.json, from the pnpm globs.

    Read from pnpm-workspace.yaml rather than hard-coded, so a new workspace
    glob is covered the day it lands instead of the day somebody remembers this
    file. A directory with a package.json that pnpm does NOT select is not a
    build unit and is not required to be scoped.
    """
    ws = os.path.join(root, 'pnpm-workspace.yaml')
    globs = []
    if os.path.exists(ws):
        doc = yaml.safe_load(open(ws, encoding='utf-8')) or {}
        globs = doc.get('packages') or []
    found = {}
    for g in globs:
        # pnpm globs here are one level deep ('apps/*') or a literal ('tests').
        base = g.rstrip('/')
        if base.endswith('/*'):
            parent = os.path.join(root, base[:-2])
            if not os.path.isdir(parent):
                continue
            entries = [os.path.join(base[:-2], d) for d in sorted(os.listdir(parent))]
        else:
            entries = [base]
        for rel in entries:
            pj = os.path.join(root, rel, 'package.json')
            if not os.path.isfile(pj):
                continue
            try:
                name = (json.load(open(pj, encoding='utf-8')) or {}).get('name')
            except Exception:
                name = None
            if name:
                found[rel.replace(os.sep, '/')] = name
    return found


# ONE skip set, shared by discovery and by the vacuity check below. Two lists
# that merely happen to agree today drift, and the drift is silent in the worst
# direction: a manifest that discovery skips but the vacuity check counts makes
# CHECK 8 fail on a repository that is in fact fully covered, and the obvious
# way to quieten that is to weaken CHECK 8.
SKIP_DIRS = {'.git', 'node_modules', 'vendor', 'testdata', '.terraform'}


def go_modules(root):
    """Every directory holding a go.mod, except the repository root.

    A Go repository has no pnpm-workspace.yaml, so `workspace_packages` returns
    nothing there and every coverage answer below is computed over the empty
    set — which reports OK. That is the vacuous pass this gate exists to
    prevent, reproduced by the gate itself. Most repositories in this fleet are
    Go multi-module, so discovery has to see them.

    The root module is excluded deliberately: it is not an area, it is the
    thing every area is part of, and requiring a scope for it would assert the
    opposite. A root go.mod is build config, and build config is a barrier.
    """
    found = {}
    skip = SKIP_DIRS
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        if 'go.mod' not in filenames:
            continue
        rel = os.path.relpath(dirpath, root).replace(os.sep, '/')
        if rel == '.':
            continue
        found[rel] = rel
    return found


def maven_modules(root):
    """Every directory holding a pom.xml, except the repository root.

    Same blindness as the Go case, in the third language on this fleet:
    SOAP-To-REST builds its admin-api, runtime, worker and four cloud adapters
    with Maven, and none of them carries a package.json or a go.mod. Without
    this, discovery there sees one Node package and three Go modules, reports
    OK, and says nothing about the seven Java modules it never opened — a pass
    computed over a fraction of the repository, which is the failure mode CHECK
    8 catches only when the fraction is ZERO.

    An aggregator pom (one whose directory is the parent of other modules) is
    NOT special-cased away. It is a real file a pull request can touch, and
    touching it affects every module beneath it, so it must be scoped or — the
    usual answer — left to the catch-all barrier.
    """
    found = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and d != 'target']
        if 'pom.xml' not in filenames:
            continue
        rel = os.path.relpath(dirpath, root).replace(os.sep, '/')
        if rel == '.':
            continue
        found[rel] = rel
    return found


PYTHON_MANIFESTS = ('pyproject.toml', 'setup.py', 'Pipfile')
PYTHON_SKIP_DIRS = ('.venv', 'venv', '__pycache__', 'site-packages')


def is_python_manifest(name):
    """A Python manifest, INCLUDING the requirements-<flavour>.txt spellings.

    Matching the bare `requirements.txt` alone was a near-miss of exactly the
    kind this gate exists to catch: one repository on this fleet pins its
    dependencies in `app/requirements-gpu.txt`, so an exact-name test found
    nothing there, and
    "no build units" over a repository of three deployable services reads as a
    legitimate answer rather than as a blind spot. `requirements-dev.txt` and
    friends are the same file for this purpose — evidence that a directory is a
    Python build unit.
    """
    return (name in PYTHON_MANIFESTS
            or (name.startswith('requirements') and name.endswith('.txt')))


def docker_units(root):
    """Every directory holding a Dockerfile, except the repository root.

    The language-agnostic backstop, and the one that answers a container-only
    repository: three separately built and separately deployed images under one
    `app/` tree, where the ONLY file that says so is a
    Dockerfile — there is no pyproject, no go.mod, nothing else to find. On this
    fleet the OCI image is the deployable unit by policy, so a directory that
    builds one is a build unit whatever language is inside it.

    `Dockerfile.gpu`, `Dockerfile.cpu`, `Dockerfile.sweeper` all count: a
    per-flavour suffix names a variant of the same unit, not a different place.
    """
    found = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        present = sorted(f for f in filenames if is_dockerfile(f))
        if not present:
            continue
        rel = os.path.relpath(dirpath, root).replace(os.sep, '/')
        if rel == '.':
            continue
        found[rel] = present[0]
    return found


def is_dockerfile(name):
    return name == 'Dockerfile' or name.startswith('Dockerfile.')


def python_units(root):
    """Every directory holding a Python manifest, except the repository root.

    The fifth language, and the one where "no build units" is most convincing:
    two repositories on this fleet are Python end to end, so before this the
    gate found nothing, `has_any_manifest` agreed there was nothing, and CHECK 8
    stayed quiet — a legitimate-looking "this repository has no build units to
    cover" over repositories that plainly do.

    A ROOT manifest is excluded for the same reason a root go.mod is: it is not
    an area, it is what every area is part of, so it belongs in the barrier.
    """
    found = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in SKIP_DIRS and d not in PYTHON_SKIP_DIRS]
        present = sorted(f for f in filenames if is_python_manifest(f))
        if not present:
            continue
        rel = os.path.relpath(dirpath, root).replace(os.sep, '/')
        if rel == '.':
            continue
        found[rel] = present[0]
    return found


GRADLE_BUILD_FILES = ('build.gradle', 'build.gradle.kts')


def gradle_modules(root):
    """Every directory holding a build.gradle[.kts], except the repository root.

    The fourth language on this fleet, and the one where blindness is total
    rather than partial: Borsh-Tablet-App is Gradle end to end, with no
    package.json, go.mod or pom.xml anywhere, so before this the gate found ZERO
    units there — and `has_any_manifest` did not know about Gradle either, so
    even CHECK 8 stayed quiet. Two blind spots that cancel out produce a green
    light over a wholly unscoped repository, which is the exact failure this
    file exists to prevent.

    `settings.gradle[.kts]` marks the build root and is intentionally NOT a
    unit: like a root go.mod, it is not an area, it is the thing every area is
    part of, and it belongs in the barrier.
    """
    found = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and d != 'build']
        if not any(f in filenames for f in GRADLE_BUILD_FILES):
            continue
        rel = os.path.relpath(dirpath, root).replace(os.sep, '/')
        if rel == '.':
            continue
        # Probe the file that actually exists, not a canonical name: the probe
        # is matched against scope globs, and a scope that names
        # `app/build.gradle.kts` would not match an invented `app/build.gradle`.
        found[rel] = next(f for f in GRADLE_BUILD_FILES if f in filenames)
    return found


def build_units(root):
    """Every unit that must be scoped or barriered, with the path to probe.

    The probe is the manifest, not the directory, because Mergify matches
    scopes against CHANGED FILE PATHS. `packages/foo` is not a path any pull
    request touches; `packages/foo/go.mod` is.
    """
    units = {}
    node = workspace_packages(root)
    if not node:
        # No pnpm-workspace.yaml. A repository can still hold Node build units
        # -- Print-Server has exactly one, services/admin-ui-web, with its own
        # type-check job in CI -- and skipping them because the workspace file
        # is absent is the same blindness in a smaller form.
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            if 'package.json' not in filenames:
                continue
            rel = os.path.relpath(dirpath, root).replace(os.sep, '/')
            if rel == '.':
                continue
            try:
                nm = (json.load(open(os.path.join(dirpath, 'package.json'),
                                     encoding='utf-8')) or {}).get('name')
            except Exception:
                nm = None
            node[rel] = nm or rel
    for rel, name in node.items():
        units[rel] = ('node', name, rel + '/package.json')
    for rel, name in go_modules(root).items():
        units.setdefault(rel, ('go', name, rel + '/go.mod'))
    for rel, name in maven_modules(root).items():
        units.setdefault(rel, ('maven', name, rel + '/pom.xml'))
    for rel, fname in gradle_modules(root).items():
        units.setdefault(rel, ('gradle', rel, rel + '/' + fname))
    for rel, fname in python_units(root).items():
        units.setdefault(rel, ('python', rel, rel + '/' + fname))
    # LAST, so a directory a real toolchain already claimed keeps that kind: the
    # Dockerfile is the backstop, not a competing answer.
    for rel, fname in docker_units(root).items():
        units.setdefault(rel, ('docker', rel, rel + '/' + fname))
    return units


def has_any_manifest(root):
    """Does this tree contain a build manifest anywhere at all?

    Distinguishes "a repository with no build units" (legitimately nothing to
    cover) from "discovery is blind here" (a green light over nothing). Only
    the second is a defect, and only this tells them apart.
    """
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if 'go.mod' in filenames or 'package.json' in filenames \
                or 'pom.xml' in filenames \
                or any(f in filenames for f in GRADLE_BUILD_FILES) \
                or any(is_python_manifest(f) for f in filenames) \
                or any(is_dockerfile(f) for f in filenames):
            return True
    return False


def fanout(root, units):
    """Transitive dependent count per package, over workspace deps only.

    Node-only: the dependency edges are read out of package.json. Go modules
    are reported without a fan-out number rather than with a wrong one.
    """
    import collections
    pkgs = dict((rel, name) for rel, (kind, name, _p) in units.items()
                if kind == 'node')
    meta = {}
    for rel, name in pkgs.items():
        try:
            meta[name] = json.load(open(os.path.join(root, rel, 'package.json'), encoding='utf-8'))
        except Exception:
            meta[name] = {}
    names = set(meta)
    rev = collections.defaultdict(set)
    for name, j in meta.items():
        deps = set()
        for k in ('dependencies', 'devDependencies', 'peerDependencies'):
            deps |= set((j.get(k) or {}).keys())
        for d in deps & names:
            rev[d].add(name)

    def closure(t):
        seen, stack = set(), [t]
        while stack:
            c = stack.pop()
            for u in rev.get(c, ()):
                if u not in seen:
                    seen.add(u)
                    stack.append(u)
        return seen

    by_name = {v: k for k, v in pkgs.items()}
    return sorted(((len(closure(n)), by_name[n], n) for n in meta), reverse=True)


# --- glob matching, Mergify's semantics --------------------------------------
def to_regex(pat):
    """`**` crosses directory separators, `*` and `?` do not.

    fnmatch.translate is wrong here: it maps `*` to `.*`, which crosses `/`, so
    `packages/*` would match `packages/connectors/aws-sqs` and the gate would
    report a package covered by a pattern Mergify does not match it with. Every
    coverage answer would be wrong in the permissive direction.
    """
    out = ['^']
    i = 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith('**', i):
            out.append('.*')
            i += 2
            if pat.startswith('/', i):
                # `a/**/b` should also match `a/b`
                out.append('/?')
                i += 1
            continue
        if c == '*':
            out.append('[^/]*')
        elif c == '?':
            out.append('[^/]')
        else:
            out.append(re.escape(c))
        i += 1
    out.append('$')
    return re.compile(''.join(out))


def matches(patterns, path):
    return any(to_regex(p).match(path) for p in patterns or [])


# --- read the configuration --------------------------------------------------
try:
    doc = yaml.safe_load(open(cfg_path, encoding='utf-8'))
except Exception as exc:
    print("FAIL [load] .mergify.yml does not load: %s" % exc)
    sys.exit(1)
if not isinstance(doc, dict):
    print("FAIL [load] .mergify.yml is not a mapping")
    sys.exit(1)

mq = doc.get('merge_queue') or {}
scopes = doc.get('scopes') or {}
files = ((scopes.get('source') or {}).get('files')) or {}
barrier_files = scopes.get('barrier_files') or {}
barriers = barrier_files.get('include') or []
# Mergify's file filter is include-minus-exclude, and reading only `include`
# turns the fail-safe catch-all barrier — `include: ["**/*"]` with the scoped
# areas excluded — into a claim that EVERY path is barriered. Coverage would
# then pass unconditionally, which is worse than no gate: it reads as green.
barrier_excludes = barrier_files.get('exclude') or []


def is_barriered(probe):
    return matches(barriers, probe) and not matches(barrier_excludes, probe)
queue_mode = mq.get('mode', 'serial')
width = mq.get('max_parallel_checks')

units = build_units(root)

if mode == '--fanout':
    tot = len(units)
    print("build units: %d" % tot)
    for count, rel, name in fanout(root, units):
        if tot and count * 100 // tot >= 5:
            print("%6d %4d%%  %-50s (%s)" % (count, 100 * count // tot, rel, name))
    sys.exit(0)

# CHECK 1 — the mode is one Mergify knows, and is not `isolated`.
#
# `isolated` drops the dependency between batches ENTIRELY, scopes or not, so
# two entries that pass alone and conflict together both merge and break main.
# That is the one property a merge queue exists to provide, so it is banned
# here rather than left to a reviewer to notice in a one-word diff.
checks.append('mode')
if queue_mode not in ('serial', 'parallel'):
    if queue_mode == 'isolated':
        fail('mode', "merge_queue.mode: isolated removes all batch dependencies; "
                     "two entries that pass alone can merge and break main. Use `parallel`.")
    else:
        fail('mode', "merge_queue.mode: %r is not serial|parallel" % (queue_mode,))

# CHECK 2 — parallel mode needs scopes to mean anything AT ALL.
#
# With no scopes every entry carries the empty set, every entry is therefore
# non-overlapping with every other, and `parallel` degrades to `isolated` — the
# banned mode, reached by omission instead of by declaration.
checks.append('parallel-needs-scopes')
if queue_mode == 'parallel' and not files:
    fail('parallel-needs-scopes',
         "merge_queue.mode is parallel but scopes.source.files declares nothing; "
         "every pull request would carry the empty scope set and run concurrently "
         "with every other, which is `isolated` by omission.")

# CHECK 3 — parallel mode needs barriers.
#
# Build config, workflow files and wide-fan-out packages do not belong to one
# area, and a scope for them would ASSERT that they do.
checks.append('parallel-needs-barriers')
if queue_mode == 'parallel' and not barriers:
    fail('parallel-needs-barriers',
         "merge_queue.mode is parallel but scopes.barrier_files.include is empty; "
         "a change to build config or a widely-imported package would be tested "
         "concurrently with the changes that depend on it.")

# CHECK 4 — coverage is total.
checks.append('coverage')
uncovered = []
for rel in sorted(units):
    _kind, _name, probe = units[rel]
    if is_barriered(probe):
        continue
    hit = False
    for _sname, sdef in (files or {}).items():
        sdef = sdef or {}
        if matches(sdef.get('include'), probe) and not matches(sdef.get('exclude'), probe):
            hit = True
            break
    if not hit:
        uncovered.append(rel)
if uncovered and queue_mode == 'parallel':
    fail('coverage',
         "%d build unit(s) match no scope and no barrier. In parallel mode "
         "an unscoped pull request carries the empty scope set and runs "
         "concurrently with EVERYTHING. Add each to a scope in .mergify.yml, or "
         "to barrier_files if it is build/toolchain/wide-fan-out:\n  %s"
         % (len(uncovered), "\n  ".join(uncovered)))

# CHECK 5 — capacities are sub-limits, never a way to exceed the global width.
#
# Mergify takes the minimum, so a capacity above the width is not an error at
# runtime — it is a number that reads like a raise and does nothing, which is
# how a width increase gets "applied" in the wrong file and reported as applied.
checks.append('capacity')
if isinstance(width, int):
    caps = dict((scopes.get('capacities') or {}))
    dflt = scopes.get('default_capacity')
    if isinstance(dflt, int):
        caps['<default_capacity>'] = dflt
    for sname, cval in caps.items():
        if isinstance(cval, int) and cval > width:
            fail('capacity',
                 "scope capacity %s=%d exceeds merge_queue.max_parallel_checks=%d; "
                 "a capacity is a sub-limit inside the global width, so this reads "
                 "like a raise and changes nothing."
                 % (sname, cval, width))

# CHECK 6 — a capped scope name must exist.
#
# A capacity on a scope that was renamed or deleted is silently ignored, and the
# scope it was meant to bound then runs at the full width.
checks.append('capacity-names-a-scope')
for sname in (scopes.get('capacities') or {}):
    if sname not in files and sname != scopes.get('merge_queue_scope', 'merge-queue'):
        fail('capacity-names-a-scope',
             "scopes.capacities names %r, which is not a declared scope; the cap is "
             "ignored and that scope runs at the full width." % (sname,))

# CHECK 7 — the merge-queue scope name does not collide with a real scope.
checks.append('merge-queue-scope-collision')
mqs = scopes.get('merge_queue_scope', 'merge-queue')
if mqs in files:
    fail('merge-queue-scope-collision',
         "scopes.merge_queue_scope=%r is also a declared scope; Mergify's own "
         "drafts would then overlap that area's pull requests." % (mqs,))

# CHECK 8 — discovery actually found something.
#
# Every answer above is computed over the discovered set, so a discovery that
# returns nothing reports OK no matter what the configuration says. That is not
# a hypothetical: this gate read only pnpm-workspace.yaml, and in a Go
# multi-module repository it found zero units and printed
# `OK: 0 workspace packages, all scoped or barriered`. A gate that cannot see
# the repository must say so in red, not pass quietly.
checks.append('discovery-non-vacuous')
if not units and has_any_manifest(root):
    fail('discovery-non-vacuous',
         "no build units were discovered, but this tree contains go.mod, "
         "package.json, pom.xml, build.gradle, a Python manifest "
         "(pyproject.toml / setup.py / requirements*.txt) or a Dockerfile. "
         "Every coverage answer "
         "above was computed over the empty set and is therefore vacuous. Teach "
         "discovery (workspace_packages / go_modules / maven_modules / "
         "gradle_modules / python_units / docker_units) this repository's "
         "layout before "
         "trusting a pass here.")

print("checks run: %s" % ",".join(checks))
if errors:
    print("FAILED: %s" % ",".join(sorted(set(errors))))
    sys.exit(1)
kinds = ('node', 'go', 'maven', 'gradle', 'python', 'docker')
print("OK: %d build units (%s), all scoped or barriered; mode=%s width=%s"
      % (len(units),
         ", ".join("%d %s" % (sum(1 for v in units.values() if v[0] == k), k)
                   for k in kinds),
         queue_mode, width))
PYEOF
}

# -----------------------------------------------------------------------------
# Self-test. One fixture per detector, asserting the SET of check ids raised —
# not how many diagnostics appeared. A count-only assertion is itself vacuous:
# delete a detector and the fixture that exists to prove it stays green, because
# a different check emits one error instead.
# -----------------------------------------------------------------------------
selftest() {
  local tmp rc out failed=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  make_fixture() { # $1 = dir, $2 = mergify body
    mkdir -p "$1"
    printf 'packages:\n  - %s\n' "'apps/*'" > "$1/pnpm-workspace.yaml"
    mkdir -p "$1/apps/alpha" "$1/apps/beta"
    printf '{"name":"@x/alpha"}' > "$1/apps/alpha/package.json"
    printf '{"name":"@x/beta"}' > "$1/apps/beta/package.json"
    printf '%s' "$2" > "$1/.mergify.yml"
  }

  expect() { # $1 = name, $2 = dir, $3 = expected failing ids (comma, sorted) or ""
    set +e
    out="$(run_reader --gate "$2" 2>&1)"
    rc=$?
    set -e
    local got
    got="$(printf '%s\n' "$out" | sed -n 's/^FAILED: //p')"
    if [ "$got" != "$3" ]; then
      echo "selftest FAIL: $1 — expected [$3] got [$got] (rc=$rc)"
      printf '%s\n' "$out" | sed 's/^/    /'
      failed=1
    else
      echo "selftest ok: $1"
    fi
  }

  # Clean: both packages scoped, parallel, barrier present.
  make_fixture "$tmp/clean" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - package.json
  default_capacity: 2
  source:
    files:
      a:
        include:
          - apps/alpha/**
      b:
        include:
          - apps/beta/**
'
  expect "clean" "$tmp/clean" ""

  # An unscoped package under parallel mode — the finding this file exists for.
  make_fixture "$tmp/uncovered" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - package.json
  source:
    files:
      a:
        include:
          - apps/alpha/**
'
  expect "uncovered package" "$tmp/uncovered" "coverage"

  # The same file under serial mode is merely an unfinished optimisation, not a
  # correctness problem — coverage must NOT fail there, or the gate blocks the
  # very repositories that have not migrated yet.
  make_fixture "$tmp/uncovered-serial" 'merge_queue:
  mode: serial
  max_parallel_checks: 1
scopes:
  source:
    files:
      a:
        include:
          - apps/alpha/**
'
  expect "uncovered under serial is not a finding" "$tmp/uncovered-serial" ""

  # `*` must not cross a separator. `apps/*` names the directories, not the
  # files inside them, so it must NOT cover apps/alpha/package.json.
  make_fixture "$tmp/star-crosses" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - package.json
  source:
    files:
      a:
        include:
          - apps/*
'
  expect "single star does not cross /" "$tmp/star-crosses" "coverage"

  # An exclude that removes a package from its only scope leaves it uncovered.
  make_fixture "$tmp/excluded" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - package.json
  source:
    files:
      a:
        include:
          - apps/**
        exclude:
          - apps/beta/**
'
  expect "exclude leaves a hole" "$tmp/excluded" "coverage"

  # isolated is banned outright.
  make_fixture "$tmp/isolated" 'merge_queue:
  mode: isolated
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - package.json
  source:
    files:
      a:
        include:
          - apps/**
'
  expect "isolated banned" "$tmp/isolated" "mode"

  # parallel with no scopes is `isolated` by omission — and every package is
  # also uncovered, so both detectors must fire.
  make_fixture "$tmp/no-scopes" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
'
  expect "parallel without scopes" "$tmp/no-scopes" "coverage,parallel-needs-barriers,parallel-needs-scopes"

  # A capacity above the width reads like a raise and does nothing.
  make_fixture "$tmp/cap-over" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - package.json
  capacities:
    a: 5
  source:
    files:
      a:
        include:
          - apps/**
'
  expect "capacity above width" "$tmp/cap-over" "capacity"

  # A capacity naming a scope that no longer exists is silently ignored.
  make_fixture "$tmp/cap-ghost" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - package.json
  capacities:
    frontend: 1
  source:
    files:
      a:
        include:
          - apps/**
'
  expect "capacity names a dead scope" "$tmp/cap-ghost" "capacity-names-a-scope"

  # The queue's own scope name colliding with a real one.
  make_fixture "$tmp/collide" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  merge_queue_scope: a
  barrier_files:
    include:
      - package.json
  source:
    files:
      a:
        include:
          - apps/**
'
  expect "merge_queue_scope collides" "$tmp/collide" "merge-queue-scope-collision"

  # A barrier may stand in for a scope: a package named only by barrier_files is
  # covered, because a barrier is the strictest possible answer.
  make_fixture "$tmp/barrier-covers" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - apps/beta/**
  source:
    files:
      a:
        include:
          - apps/alpha/**
'
  expect "barrier counts as coverage" "$tmp/barrier-covers" ""

  # --- the three detectors added when the gate met its first Go repository ---

  # A catch-all barrier must not swallow coverage. `include: ["**/*"]` with the
  # scoped areas excluded is the FAIL-SAFE construction — an unclassified path
  # becomes a barrier instead of becoming unscoped-and-maximally-parallel — but
  # a reader that ignores `exclude` sees it as "everything is barriered" and
  # then passes unconditionally. Here `apps/beta` is excluded from the barrier
  # AND named by no scope, so it is genuinely uncovered and must be reported.
  make_fixture "$tmp/catchall-exclude" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - apps/alpha/**
      - apps/beta/**
  source:
    files:
      a:
        include:
          - apps/alpha/**
'
  expect "catch-all barrier honours exclude" "$tmp/catchall-exclude" "coverage"

  # The same construction, correctly maintained: every excluded pattern is a
  # pattern some scope includes. Nothing is uncovered.
  make_fixture "$tmp/catchall-ok" 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - apps/alpha/**
      - apps/beta/**
  source:
    files:
      a:
        include:
          - apps/alpha/**
      b:
        include:
          - apps/beta/**
'
  expect "catch-all barrier with total coverage" "$tmp/catchall-ok" ""

  # Go modules are build units. Without this the gate reads a Go repository as
  # empty and reports OK over an entirely unscoped tree.
  mkdir -p "$tmp/go-repo/services/alpha" "$tmp/go-repo/services/beta"
  printf 'module x/alpha
' > "$tmp/go-repo/services/alpha/go.mod"
  printf 'module x/beta
'  > "$tmp/go-repo/services/beta/go.mod"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - services/alpha/**
  source:
    files:
      a:
        include:
          - services/alpha/**
' > "$tmp/go-repo/.mergify.yml"
  expect "go modules are discovered and covered" "$tmp/go-repo" ""

  # ... and are reported when they are NOT covered: beta is excluded from the
  # barrier and named by no scope.
  mkdir -p "$tmp/go-uncovered/services/alpha" "$tmp/go-uncovered/services/beta"
  printf 'module x/alpha
' > "$tmp/go-uncovered/services/alpha/go.mod"
  printf 'module x/beta
'  > "$tmp/go-uncovered/services/beta/go.mod"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - services/alpha/**
      - services/beta/**
  source:
    files:
      a:
        include:
          - services/alpha/**
' > "$tmp/go-uncovered/.mergify.yml"
  expect "uncovered go module is reported" "$tmp/go-uncovered" "coverage"

  # Maven modules, the third language on this fleet. SOAP-To-REST's services
  # carry neither a package.json nor a go.mod, so before pom.xml discovery the
  # gate there saw a handful of Go and Node units, reported OK, and never opened
  # the seven Java modules that are most of the repository. CHECK 8 could not
  # catch it: discovery was not empty, only partial.
  #
  # `target/` is excluded from the walk for the same reason `node_modules` is —
  # a build directory can hold a copied pom.xml, and a unit that exists only
  # after a build is not a path a pull request touches.
  mkdir -p "$tmp/mvn-repo/services/alpha" "$tmp/mvn-repo/services/beta" \
           "$tmp/mvn-repo/services/alpha/target/classes"
  printf '<project/>' > "$tmp/mvn-repo/services/alpha/pom.xml"
  printf '<project/>' > "$tmp/mvn-repo/services/beta/pom.xml"
  printf '<project/>' > "$tmp/mvn-repo/services/alpha/target/classes/pom.xml"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - services/alpha/**
  source:
    files:
      a:
        include:
          - services/alpha/**
' > "$tmp/mvn-repo/.mergify.yml"
  expect "maven modules are discovered and covered" "$tmp/mvn-repo" ""

  # ... and reported when uncovered, the direction that matters: without this
  # the fixture above would also pass with discovery deleted.
  mkdir -p "$tmp/mvn-uncovered/services/alpha" "$tmp/mvn-uncovered/services/beta"
  printf '<project/>' > "$tmp/mvn-uncovered/services/alpha/pom.xml"
  printf '<project/>' > "$tmp/mvn-uncovered/services/beta/pom.xml"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - services/alpha/**
      - services/beta/**
  source:
    files:
      a:
        include:
          - services/alpha/**
' > "$tmp/mvn-uncovered/.mergify.yml"
  expect "uncovered maven module is reported" "$tmp/mvn-uncovered" "coverage"

  # Gradle, the fourth language — and the case where the two blind spots
  # cancelled out. Borsh-Tablet-App carries no package.json, go.mod or pom.xml
  # anywhere, so discovery found zero units AND `has_any_manifest` saw no
  # manifest, which meant CHECK 8 stayed quiet too: a green light over a wholly
  # unscoped repository. Both halves are fixed, and this fixture is the one that
  # would go red if either regressed.
  #
  # `settings.gradle.kts` marks the build root and must NOT become a unit; the
  # root of a build is not an area, it is what every area belongs to.
  mkdir -p "$tmp/gradle-repo/app/alpha" "$tmp/gradle-repo/app/beta" \
           "$tmp/gradle-repo/app/alpha/build/tmp"
  printf 'rootProject.name = "x"' > "$tmp/gradle-repo/settings.gradle.kts"
  printf 'plugins {}' > "$tmp/gradle-repo/app/alpha/build.gradle.kts"
  printf 'plugins {}' > "$tmp/gradle-repo/app/beta/build.gradle"
  printf 'plugins {}' > "$tmp/gradle-repo/app/alpha/build/tmp/build.gradle.kts"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - app/alpha/**
  source:
    files:
      a:
        include:
          - app/alpha/**
' > "$tmp/gradle-repo/.mergify.yml"
  expect "gradle modules are discovered and covered" "$tmp/gradle-repo" ""

  # The direction that proves discovery ran at all.
  mkdir -p "$tmp/gradle-uncovered/app/alpha" "$tmp/gradle-uncovered/app/beta"
  printf 'plugins {}' > "$tmp/gradle-uncovered/app/alpha/build.gradle.kts"
  printf 'plugins {}' > "$tmp/gradle-uncovered/app/beta/build.gradle.kts"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - app/alpha/**
      - app/beta/**
  source:
    files:
      a:
        include:
          - app/alpha/**
' > "$tmp/gradle-uncovered/.mergify.yml"
  expect "uncovered gradle module is reported" "$tmp/gradle-uncovered" "coverage"

  # A Gradle-only tree with NOTHING scoped must be red, not quiet. This is the
  # literal pre-fix Borsh-Tablet-App shape: parallel mode, no scopes at all.
  mkdir -p "$tmp/gradle-blind/app/alpha"
  printf 'plugins {}' > "$tmp/gradle-blind/app/alpha/build.gradle.kts"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
' > "$tmp/gradle-blind/.mergify.yml"
  # All three fire, and the third is the one this fixture is really about:
  # `coverage` naming `app/alpha` proves discovery SAW the module. Without
  # Gradle discovery the first two would still fire and the fixture would look
  # like it was testing something.
  expect "gradle repo with no scopes at all is reported" "$tmp/gradle-blind" \
         "coverage,parallel-needs-barriers,parallel-needs-scopes"

  # Python, the fifth language, and the one where "this repository has no build
  # units" reads most convincingly: two repositories on this fleet are Python
  # end to end and carry no package.json, go.mod, pom.xml or build.gradle
  # anywhere, so before
  # this discovery found nothing AND `has_any_manifest` agreed there was
  # nothing to find — the same both-halves-blind shape Gradle had.
  #
  # A virtualenv is skipped: `.venv/**` is thousands of vendored manifests, and
  # a scope map is not expected to name any of them.
  mkdir -p "$tmp/py-repo/svc/alpha" "$tmp/py-repo/svc/beta" \
           "$tmp/py-repo/.venv/lib/site-packages/thing"
  printf 'requests\n' > "$tmp/py-repo/requirements.txt"
  printf '[project]\nname = "alpha"\n' > "$tmp/py-repo/svc/alpha/pyproject.toml"
  printf 'from setuptools import setup\n' > "$tmp/py-repo/svc/beta/setup.py"
  printf 'x\n' > "$tmp/py-repo/.venv/lib/site-packages/thing/requirements.txt"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - svc/alpha/**
  source:
    files:
      a:
        include:
          - svc/alpha/**
' > "$tmp/py-repo/.mergify.yml"
  # The ROOT requirements.txt is deliberately not a unit — like a root go.mod it
  # is not an area, it is what every area is part of — so it must not show up as
  # an uncovered `.`, and `svc/beta` must be barriered rather than invisible.
  expect "python units are discovered and covered" "$tmp/py-repo" ""

  # The direction that proves Python discovery ran at all.
  mkdir -p "$tmp/py-uncovered/svc/alpha" "$tmp/py-uncovered/svc/beta"
  printf '[project]\nname = "alpha"\n' > "$tmp/py-uncovered/svc/alpha/pyproject.toml"
  printf '[project]\nname = "beta"\n' > "$tmp/py-uncovered/svc/beta/pyproject.toml"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - svc/alpha/**
      - svc/beta/**
  source:
    files:
      a:
        include:
          - svc/alpha/**
' > "$tmp/py-uncovered/.mergify.yml"
  expect "uncovered python unit is reported" "$tmp/py-uncovered" "coverage"

  # The language-agnostic backstop, and the shape that motivated it. In
  # a container-only repository, `app/merge` and `app/sweeper` are separately
  # built and separately deployed images whose ONLY declaration is a Dockerfile —
  # there is no pyproject, no go.mod, no package.json anywhere in the tree — and
  # `app/` pins its dependencies in `requirements-gpu.txt`, which an exact-name
  # `requirements.txt` test does not match. Both halves are asserted here: a
  # flavoured requirements file IS a manifest, and a Dockerfile IS a build unit.
  mkdir -p "$tmp/docker-repo/app/merge" "$tmp/docker-repo/app/sweeper"
  printf 'torch\n' > "$tmp/docker-repo/app/requirements-gpu.txt"
  printf 'FROM scratch\n' > "$tmp/docker-repo/app/Dockerfile.gpu"
  printf 'FROM scratch\n' > "$tmp/docker-repo/app/merge/Dockerfile.cpu"
  printf 'FROM scratch\n' > "$tmp/docker-repo/app/sweeper/Dockerfile"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - app/sweeper/**
  source:
    files:
      s:
        include:
          - app/sweeper/**
' > "$tmp/docker-repo/.mergify.yml"
  expect "dockerfile-only units are discovered and covered" "$tmp/docker-repo" ""

  # The direction that proves it ran: drop the barrier's catch-all so the two
  # Dockerfile-only directories are neither scoped nor barriered.
  mkdir -p "$tmp/docker-uncovered/svc/alpha" "$tmp/docker-uncovered/svc/beta"
  printf 'FROM scratch\n' > "$tmp/docker-uncovered/svc/alpha/Dockerfile"
  printf 'FROM scratch\n' > "$tmp/docker-uncovered/svc/beta/Dockerfile"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
    exclude:
      - svc/alpha/**
      - svc/beta/**
  source:
    files:
      a:
        include:
          - svc/alpha/**
' > "$tmp/docker-uncovered/.mergify.yml"
  expect "uncovered dockerfile unit is reported" "$tmp/docker-uncovered" "coverage"

  # Blind discovery must be red, not quiet. A manifest exists but sits where
  # discovery does not look, so every coverage answer is computed over the
  # empty set. Reporting OK there is how this gate passed a wholly unscoped
  # Go repository before CHECK 8 existed.
  mkdir -p "$tmp/vacuous/nested"
  printf 'module x/root
' > "$tmp/vacuous/nested/go.mod"
  printf '%s' 'merge_queue:
  mode: parallel
  max_parallel_checks: 2
scopes:
  barrier_files:
    include:
      - "**/*"
  source:
    files:
      a:
        include:
          - nested/**
' > "$tmp/vacuous/.mergify.yml"
  expect "discovery sees a nested go module" "$tmp/vacuous" ""

  if [ "$failed" -ne 0 ]; then
    echo "check-mergify-scopes: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "check-mergify-scopes: self-test passed"
}

case "${1:-}" in
  --selftest) selftest ;;
  --fanout)   run_reader --fanout "$REPO_ROOT" ;;
  *)          run_reader --gate "$REPO_ROOT" ;;
esac
