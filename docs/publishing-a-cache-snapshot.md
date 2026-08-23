# Publishing a cache snapshot

A pool's hosts **read** a snapshot on boot and never write one. This is the other
half: the scheduled run that builds it.

> **Read `modules/ci-runner-cache-warmer` first — this document is the fallback
> now.** That module does everything below from Cloud Build, in the project that
> owns the bucket: no workflow file, no workload-identity federation, no OIDC
> attribute mapping, no schedule in your repository, and it fills the *build*
> cache in the same run. Follow this document only when your build genuinely
> cannot run in Cloud Build — or when the project has no Cloud Build GitHub
> connection yet.

Read `modules/ci-runner-cache-publisher/README.md` first for *who* may publish
and why it cannot be a host. This document is *what* to run.

## What you need already

- `ci-runner-cache-bucket` applied once in the project;
- the pool pointed at it (`cache_snapshot_bucket`);
- `ci-runner-cache-publisher` applied for this pool, and its
  `publish_workflow_path` naming the workflow file below. The binding pins the
  **file name** — a workflow at a different path gets a token GCP will not
  exchange.

## The workflow

Copy this into the path you gave `publish_workflow_path` (default
`.github/workflows/publish-cache-snapshot.yml`). It runs on a **GitHub-hosted**
runner, not on the fleet: the fleet's hosts are the consumers of what it
produces, and running it there would put the publishing credential on a machine
that executes pull-request code.

**It is two jobs, and that is not tidiness.** `CACHE_PREPARE` runs third-party
code — npm lifecycle scripts, sdist builds, Maven plugins — and a job that has
`id-token: write` exports `ACTIONS_ID_TOKEN_REQUEST_URL` and `_TOKEN` to every
process in it. One compromised transitive dependency in a job holding the
publishing credential mints its own token, publishes a snapshot of its choosing,
and every host in the pool unpacks it as root. So the job that installs holds
`contents: read` and nothing else; the job that publishes only downloads the
archive, re-scans it and uploads it. Do not merge them back.

You cannot, in fact, merge them back: the script refuses to run the install and
hold the credential in one process, so a run that sets `CACHE_PREPARE` while
setting neither `CACHE_ARCHIVE_OUT` nor `CACHE_DRY_RUN` — that is, one asking to
build and then upload — dies before the install starts. Build with
`CACHE_ARCHIVE_OUT` (or `CACHE_DRY_RUN=1` to build and scan without keeping the
artifact), publish with `CACHE_ARCHIVE_IN`, in two separate runs. The split was
an argument the code did not previously make; now it is a control.

```yaml
name: publish-cache-snapshot

on:
  schedule:
    - cron: '17 3 * * *'
  workflow_dispatch:

# Nothing at the top level. Each job takes exactly what it needs, and the split
# is void if `id-token: write` is granted here.
permissions: {}

concurrency:
  group: publish-cache-snapshot
  cancel-in-progress: false

# Do NOT add `workflow_call`. The identity binding pins this file's path, so a
# caller passing an input that reaches CACHE_PREPARE would satisfy both the
# binding and the script's event guard. This file takes no inputs.

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read           # and nothing else — this job runs the install
    steps:
      # `persist-credentials: false` on every checkout in this file, and it
      # matters most here. The default writes the job's `GITHUB_TOKEN` into
      # `.git/config`, in the same workspace where `CACHE_PREPARE` runs
      # third-party install code — and the stated premise of the two-job split
      # is that this job holds nothing worth stealing. The token is scoped to
      # `contents: read`, so what it would cost is source disclosure rather
      # than a write; neither job uses it for anything, so turning it off costs
      # nothing at all.
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          persist-credentials: false

      # The scripts live in the fleet repository. Pin the COMMIT, not the tag:
      # this repository's release process floats `v5` forward, and a tag that
      # moves changes the script that later runs beside the credential. Resolve
      # once with:
      #   git ls-remote https://github.com/Dima-Spectorr/ci-runner-infra refs/tags/<tag>^{}
      #
      # Do NOT pin a release older than v5.33.0. Before v5.27.0 the content
      # scan could be switched off for a file by the prepare command writing
      # one NUL byte in front of the credential, and one process could both run
      # that command and hold the publishing credential. v5.27.0 itself parses
      # CACHE_SCAN_ALLOW_FILE wrongly: an indented entry is silently dropped,
      # so the scan refuses a digest that is visibly on the list. v5.28.0 fixes
      # that but prints a sha256 for every refused file at or above the size
      # floor, including a `user:password@` URL whose remaining bytes are a
      # published README -- a hash of a mostly-public carrier is an offline
      # oracle for the one field that is not public. v5.29.0 fixes that, and
      # still misses a registry token written behind one byte that is not valid
      # UTF-8: its `_authToken` rule is a bracket expression, and on the
      # runner's UTF-8 locale a bracket expression matches characters, not
      # bytes. The prepare command that writes the cache is untrusted code, so
      # that is a bypass anything installed can reach. v5.30.0 pins the byte
      # locale on every grep that runs a credential pattern, and matches
      # `_authToken` as a bare substring -- which refuses a clean tree, because
      # `neo4j-driver` names a private field exactly that in eight files. The
      # registry-token rule has no allowlist escape on purpose, so each of those
      # is a refusal nobody can clear, and the only way out an operator is left
      # with is deleting the rule. v5.31.0 matches the token being GIVEN A VALUE
      # instead of merely appearing, and still cannot upload: it published with
      # `gcloud storage cp`, which lists the destination bucket, and the
      # publisher's grants are all conditioned on an object prefix. v5.33.0
      # uploads through the Storage JSON API, naming the object.
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          persist-credentials: false
          repository: Dima-Spectorr/ci-runner-infra
          ref: <commit sha of the pinned tag>   # >= v5.33.0
          path: .ci-runner-infra

      - run: sudo apt-get update && sudo apt-get install -y libcap2-bin

      - name: Build the snapshot
        env:
          CACHE_PREPARE: npm ci --ignore-scripts
          CACHE_ARCHIVE_OUT: ${{ runner.temp }}/snap.tar.gz
        run: bash .ci-runner-infra/scripts/ci/publish-cache-snapshot.sh

      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: cache-snapshot
          path: ${{ runner.temp }}/snap.tar.gz
          retention-days: 1

  publish:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write          # the credential lives here, and no install does
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          persist-credentials: false
          repository: Dima-Spectorr/ci-runner-infra
          ref: <commit sha of the pinned tag>   # >= v5.33.0
          path: .ci-runner-infra

      - run: sudo apt-get update && sudo apt-get install -y libcap2-bin

      - uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4.3.0
        with:
          name: cache-snapshot
          path: ${{ runner.temp }}

      - uses: google-github-actions/auth@c200f3691d83b41bf9bbd8638997a462592937ed # v2.1.13
        with:
          workload_identity_provider: ${{ vars.CACHE_WIF_PROVIDER }}
          service_account: ${{ vars.CACHE_PUBLISHER_SA }}

      - uses: google-github-actions/setup-gcloud@e427ad8a34f8676edf47cf7d7925499adf3eb74f # v2.2.1

      - name: Publish the snapshot
        env:
          CACHE_POOL: ${{ vars.CACHE_POOL }}
          CACHE_BUCKET: ${{ vars.CACHE_BUCKET }}
          CACHE_ARCHIVE_IN: ${{ runner.temp }}/snap.tar.gz
        run: bash .ci-runner-infra/scripts/ci/publish-cache-snapshot.sh
```

`CACHE_PREPARE` is the only line most repositories change. It is whatever
installs this repository's dependencies, and it **must not run lifecycle
scripts** — `npm ci --ignore-scripts`, `mvn -B -o dependency:go-offline`,
`go mod download`, `pip download --no-build-isolation -r requirements.txt`, or
several joined with `&&`. Bare `npm ci` runs `postinstall` from every transitive
dependency and `pip download` builds sdists; the job split is what keeps that
from reaching the credential, but there is no reason to run it at all. It runs
with every cache variable pointed at an empty staging tree, so what it downloads
is what gets published.

It also runs in a **process group of its own, under a timeout**, and that group
is killed before anything is scanned. `sh -euc` returning is not evidence the
install stopped — a lifecycle script that forks into the background keeps running
as the same user with the staging tree in reach, which would make every scan a
statement about a tree that is still being written. An install that legitimately
needs longer than an hour sets `CACHE_PREPARE_TIMEOUT` (seconds); one that hits
the limit fails the run rather than publishing a half-populated cache. It must
be a positive whole number: `0` is the one value `timeout` reads as *no limit at
all*, and it is also the one an operator reaches for to mean "don't wait", so the
script refuses it instead of silently disarming the bound. If the group does not
come up as its own, the run is refused too — an unreapable install is one this
run cannot bound, and the digest pin below is the detector, not the fix.

**Do not put a registry token in `CACHE_PREPARE`.** Repository *variables* are
not masked in logs, and a credential that the install writes into the cache is a
credential published to every host in the pool. The script scans for both, and
that scan is a floor, not a guarantee.

## A Windows pool

A Windows pool publishes into the **same bucket, the same way, with the same
publish job**. Only the build half changes, and it changes because it has to:

```yaml
  build:
    runs-on: windows-latest
    permissions:
      contents: read           # and nothing else — this job runs the install
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          persist-credentials: false

      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          persist-credentials: false
          repository: Dima-Spectorr/ci-runner-infra
          ref: <commit sha of the pinned tag>   # >= v5.35.0
          path: .ci-runner-infra

      - name: Build the snapshot
        shell: pwsh
        env:
          CACHE_PREPARE: npm ci --ignore-scripts
          CACHE_ARCHIVE_OUT: ${{ runner.temp }}\snap.tar.gz
        run: .\.ci-runner-infra\scripts\ci\build-cache-snapshot.ps1

      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: cache-snapshot
          path: ${{ runner.temp }}\snap.tar.gz
          retention-days: 1
```

The `publish` job above is **unchanged** — same `ubuntu-latest`, same
`publish-cache-snapshot.sh`, same `CACHE_ARCHIVE_IN`. The credential scan, the
size bounds, the write-once name and the pointer swap are not re-derived for
Windows; the archive crossed a job boundary, so the publish job treats it as
input and applies all four to it exactly as it does to a Linux one. There is one
copy of those rules and it is on the side that already had them.

**With one exception, and it is about the artifact, not about Windows.** The
publish job's refusal happens *after* `upload-artifact` has already stored the
archive, and a stored artifact is downloadable by anyone who can read the
repository from that moment on. Refusing to publish it does not take it back. So
the *name* half of the credential scan — the fifteen filenames a tool writes its
own credentials into: `.npmrc`, `.netrc`, `gha-creds-*.json`, `*.pem` and the
rest — also runs in the build job, in `build-cache-snapshot.ps1`, before the
archive is written at all. The list is deliberately a second copy of the one in
`publish-cache-snapshot.sh`, because the build job has no reachable `find`; what
keeps a duplicate honest is that `build-cache-snapshot.selftest.sh` reads both
lists and fails if they differ by a single name.

The *content* half — `CREDENTIAL_PATTERNS` over the bytes of every cached file —
still runs only in the publish job. It needs a regex engine the build job does
not have, and unlike the name pass it is not cheap. Closing that gap by
extracting the content pass into a script both sides can call is tracked
separately; until then the honest statement is that a credential embedded in
cache *content* is caught after the artifact exists, and one written into a
tool's *config* is caught before it does.

**The key needs nothing new.** `host_os` is a property of a *pool* and pool names
are unique, so a Windows pool is its own `cache/<pool>/` and cannot collide with a
Linux pool's objects by construction. Set `CACHE_POOL` to the Windows pool's name
and there is nothing further to arrange.

**Why not just run the shell script under git-bash on `windows-latest`.** Two
reasons, both controls rather than inconveniences:

* the install is bounded by a **process group** (`set -m`, `kill -- -$pgid`, read
  back from `/proc`). Windows has neither. The build script uses a **job object**
  with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` instead, which is the only Windows
  primitive with the property the process-group argument needs: a kernel-held set
  a process cannot leave, whose children join it, terminated as a whole. The
  timeout, the refusal to publish a half-populated cache, and `0` being rejected
  rather than read as *no limit at all* are all identical to the Linux side.
* the staging tree would be a **msys path** (`/tmp/...`). Native npm, NuGet and
  Maven on Windows do not read one, so a prepare command pointed at it caches
  somewhere else entirely and publishes an empty snapshot — the failure that
  looks exactly like success. The build script stages under `RUNNER_TEMP` and
  exports native paths, and refuses an empty tree rather than shipping it.

**Do not give the Windows build job `id-token: write`.** The split is the same
split and it is enforced the same way: the script refuses to start the install if
it can see `ACTIONS_ID_TOKEN_REQUEST_URL`, `CACHE_POOL` or `CACHE_BUCKET`, so a
merged job dies before any third-party code runs.

One extra refusal exists on this side. A **reparse point** anywhere in the staged
tree fails the build, because every host would refuse the snapshot on arrival for
the same reason (a junction names a path outside the tree that the per-slot copy
would follow). Failing here means it is refused once, in a run someone is
watching, rather than silently on every boot of every host in the pool.

**A Windows pool consumes what this publishes, on the same terms.** Phase 7 of
`windows-host-startup.ps1` -- which ships in the module, not in the image, so it
arrives on the next instance-template roll rather than the next image build --
fetches this pool's `current` pointer and unpacks the snapshot over `C:\ci-cache` before
the master is scanned and sealed — same prefix, same read-only grant, same
age/size/free-space bounds, same 60-second budget, same verdict strings. Nothing
in this document changes for a Windows pool; it is listed here because the
*verification* below differs.

The scan includes the staging directory ITSELF, not only what is under it: a
prepare command that deletes the stage and puts a junction in its place leaves a
tree whose descendants all look ordinary while `tar -C` packs from wherever the
junction points. And a stage that is refused is **left on disk** for the runner's
own teardown to reclaim — Windows PowerShell 5.1's `Remove-Item -Recurse`
descends a junction, so deleting a tree that was just proved to contain one would
delete the junction's target as the cleanup for refusing it.

## The five rules the script enforces so you do not have to

1. **Built from the default branch into an empty tree.** Never an archive of a
   host's live cache. A slot's cache holds whatever job last ran there, including
   a fork's pull request; a host's master holds only the image's content plus an
   earlier snapshot's. Archiving either re-admits untrusted output or compounds
   an earlier mistake.
2. **Scanned with the host's own rules before upload** — links, device nodes,
   setuid, file capabilities and credential files. A snapshot that a host would
   refuse fails here instead: once, loudly, in a run someone is watching, rather
   than silently on every boot of every host. **Plus one pass the host does not
   have**: a content pass for embedded registry tokens and private keys. A host
   greps nothing — so whatever that pass lets through is unpacked as root on
   every host in the pool with nothing downstream to catch it.
3. **Scanned again in the publishing job, on what it received.** The archive
   crosses a job boundary, and the job that built it is the one that ran
   third-party code — so the job holding the credential unpacks it, with the
   host's own decompression bound, and re-runs every check before uploading a
   byte. It also refuses any archive member that is not a plain file or a
   directory.
4. **Write-once names.** `<UTC>-<digest>.tar.gz`, never reused. The bucket
   measures age per generation, so an object refreshed in place is a generation
   aged zero that never expires — the age bound configured and doing nothing. The
   IAM grant carries no `storage.objects.delete`, so a reused name fails.
5. **The pointer swaps last, with a generation precondition.** A host reading
   mid-publish gets the previous snapshot, which is stale at worst. Two
   publishers racing produce one winner and one loud failure.

The script also refuses to run at all from a `pull_request_target`,
`workflow_run` or `issue_comment` event. Those assert the **default branch**
while running fork-authored code, so the identity binding alone would still hand
out the credential — this is the check that turns such an edit into a failed run.

Two properties of the scan are worth knowing before you read a refusal:

- **Every file is read, including the ones that look binary.** `grep` classifies
  a file as binary from its first NUL byte and would skip it; the prepare command
  is third-party install code, so letting it decide what gets scanned by writing
  one NUL is not a bound. The cost is reading a few GiB of compressed blobs, and
  a real risk of chance matches in them — which is why every pattern has to be
  specific enough to survive random bytes. Measured: the URL rule without a
  scheme in front of it matched random data roughly once per gibibyte, so it
  carries an explicit scheme list. If you add a pattern, test it against
  `/dev/urandom` before you rely on it, because a rule that refuses good
  snapshots is a rule someone deletes.
- **The archive is unpacked and scanned again, in every mode**, not just in the
  credentialed job — and the archive's sha256 is pinned across the gap between
  that scan and the upload. What gets shipped has to be what got scanned. The
  prepare command runs in a process group of its own and that group is killed
  before anything is scanned, so an install that daemonises cannot still be
  writing; the second scan and the digest are what would catch it if it were.

## When the content scan refuses

The credential pass finds a **file**, and in a dependency cache a file's name is
a content hash — `pnpm-store/v3/files/72/93a11b…` names nothing you can act on.
So the refusal also prints which pattern fired, how many times, and on which
line:

```
the embedded-credential pass matched in pnpm-store/v3/files/72/93a11b…
  file: 47 bytes, 3 line(s)
  url-embedded-basic-auth: 1 match(es), first on line 2
    scheme: mongodb
  no digest is printed for this file, and no list will excuse it at this size.
  A registry token is never excusable; a URL credential is, but only in a file
  of at least 1024 bytes, because below that its hash is an oracle for its own
  contents. Fix the cause instead -- a prepare command that authenticates, or a
  dependency that has no business being in the tree
```

The refusal answers two different questions, and confusing them is how the
digest itself becomes the leak:

| Rule | May a list excuse it? | Does the log print its digest? |
|---|---|---|
| `registry-auth-token` | never | never |
| `private-key-header` | yes, at any size | yes, at ≥1024 bytes |
| `url-embedded-basic-auth` | yes, at ≥1024 bytes — **`CACHE_SCAN_ALLOW_FILE` only** | never — compute it yourself |

A file is excusable only if **every** rule it trips is: a README that documents
both a registry token and a connection string is not half-excusable, and no list
will take it.

The asymmetry is about entropy, not size. Under a `private-key-header` the bytes
are key material — even a 230-byte ed25519 fixture holds more than anyone can
walk — so its digest gives an attacker nothing, and the 1024-byte floor there is
only because the rule matches a *header*: sixty bytes of header in front of a
short string is not key material. A `user:password@` URL is the opposite. It
lives in a package's published README, `.d.ts` or parser test, so every byte
except the credential is already on npm; the lines above add the exact byte
count, the line count, the match line and the scheme, and an unsalted sha256 of
a nearly-known plaintext is an offline oracle with no rate limit. So that class
is excusable and its digest is still never printed: compute it off the log with
the `CACHE_DRY_RUN=1` invocation below.

Under 1024 bytes a URL hit has no escape hatch at all — a list entry is itself a
published hash, and for a bare `mongodb://user:pass@host` writing it into the
repository is the same disclosure as printing it. That is deliberate. A short
file that is nothing but a credential is the one case where "it's only a
fixture" and "it's a live secret" look identical from the outside, so the gate
declines to be the thing that decides. Look at the file and fix the cause.

It never prints the matched text, and neither should you: a CI log is readable
by everyone who can see the run, so pasting the line into an issue publishes the
thing the gate just stopped. The scheme is the tell — `https` in front of a
`user:pass@` on a registry URL is a real credential your prepare command wrote;
`mongodb`, `postgres` or `git+ssh` is almost always a package's test fixture.

One list drives both the match and the printing. It covers the schemes a
credential actually travels in — `http(s)`, `ftp(s)`, `sftp`, `ssh`, the VCS
family (`git`/`hg`/`bzr`/`svn`, each with an optional `+ssh`, `+http(s)` or
`+file`), the database and broker schemes (`postgres`, `mysql`, `mariadb`,
`mongodb(+srv)`, `redis(s)`, `amqp(s)`), object storage (`s3`, `gs`) and the
directory and mail schemes (`ldap(s)`, `smtps`, `imap`). Adding a scheme widens
what the gate catches, so a missing one is a real gap worth filing; the list is
not an exclusion list.

The scheme is printed only when it is one the script recognises, and *"not a
recognised URL scheme"* is not a bug to fix by widening the list. Cache content
is raw blobs and concatenated fields; the characters in front of a `://` are not
reliably a scheme word, and echoing them unfiltered would print the bytes this
whole function exists not to print. It means: go and look at that line yourself.

Either way the answer is not to widen the exclusions. Reproduce it locally with
the `CACHE_DRY_RUN=1` invocation below, open that file at that line, and fix the
cause: a real token means the prepare command is authenticating and must stop.

### Excusing one PEM fixture by digest

A dependency that ships a PEM test fixture will keep tripping the pass forever,
and there is no pattern narrow enough to tell that fixture from a real key — the
bytes are the same shape. Widening `CREDENTIAL_PATTERNS` to make it go away
removes the rule for every future file too, which is how a gate stops catching
anything. Excuse *that one file* instead:

```yaml
# in BOTH jobs of publish-cache-snapshot.yml
env:
  # <package>@<version> ships this PEM in its own test fixtures — confirmed
  # present in the published tarball (`npm pack <package>@<version>`), so it is
  # not something the prepare command wrote. Verified <date>.
  CACHE_SCAN_ALLOW_DIGESTS: <the 64-hex sha256 the refusal printed>
```

Both jobs, because the credentialed job re-scans what it received and would
otherwise refuse the archive the build job just approved. Entries are full
64-character sha256 digests, separated by commas or whitespace; a prefix is
rejected at startup, because a prefix excuses every file that happens to share
it. The digest is the file's content, so the excusal stops applying the moment
that package changes a byte — which is the point: an upgraded dependency that
starts shipping a real key is refused again.

**A literal in the workflow file, never `${{ vars.* }}`, a `workflow_dispatch`
input, or another job's output.** This is the one input to a pipeline whose
output every host unpacks as root; keeping it as a literal keeps changing it a
diff that goes through code review and branch protection, which a repository
variable is precisely not.

Four bounds make this safe to have at all:

- **It excuses two rules, and never the third.** A `registry-auth-token` hit is
  refused with the allowlist set, before the digest is even computed: no
  dependency has a legitimate reason to ship one, so there is nothing to excuse,
  and that is what stops an operator allowlisting their way past a live
  credential. `private-key-header` and `url-embedded-basic-auth` can be excused,
  because dependencies demonstrably ship both — published test keys, and README
  connection strings with `user:password@` in them — though the second is
  reachable only from `CACHE_SCAN_ALLOW_FILE`, for the reason below. The set is a whitelist, not
  "anything but the token rule": a pattern added to the scan later is
  unexcusable until someone decides otherwise in a diff.

  Having no escape hatch is exactly why that rule's pattern has to be exact. An
  unexcusable rule with a false positive in it is a rule someone deletes, and a
  bare `_authToken` substring produced two, both on real trees. `googleapis`
  ships four doc comments reading `"authToken": "my_authToken"`, where the token
  is the tail of a longer identifier. `neo4j-driver` names a private field
  exactly `_authToken` and ships it in eight files, where no word boundary helps
  because the identifier *is* the string. So the rule matches `_authToken`
  **given a value**: followed by `=` or `:` through optional quotes and space,
  or by the quote-space-quote of yarn v1's `"…:_authToken" "token"`, which
  separates key from value by juxtaposition. It must also not be preceded by
  `.`, `$` or an alphanumeric. A field is read or bound; a credential is given
  a value. Every form a tool actually writes is a case in the suite: an
  `.npmrc` line, indented, spaces or tabs around the `=`, commented out with
  `;`, quoted as a JSON key in `npm config ls --json`, assigned `${NPM_TOKEN}`,
  npm's environment form `npm_config__authToken=`, and yarn's juxtaposed pair.
  What it gives up is a key spelled with a dot — `registry.example.com._authToken=`
  — which nothing writes, and which is the price of the one class member the
  neo4j evidence requires.

  Every grep that
  runs these patterns — the two that decide refusal and the three that write the
  refusal log — runs under `LC_ALL=C` for the same reason they run under `-a`:
  they read bytes. With GNU grep on glibc in a UTF-8 locale — which
  `ubuntu-latest` sets — a character class matches one *character*, so a byte
  that is not valid UTF-8 in front of the pattern makes the rule miss, and the
  prepare command that writes it is untrusted code. Unpinned, the two deciding
  greps are a bypass; unpinned, the reporter's three are a refusal that cannot
  name the rule that caused it.
- **Every rule a file trips must be excusable**, and a `url-embedded-basic-auth`
  hit must additionally be in a file of at least 1024 bytes. See the table in
  the refusal section above.
- **A `url-embedded-basic-auth` hit can only be excused through
  `CACHE_SCAN_ALLOW_FILE` — never `CACHE_SCAN_ALLOW_DIGESTS`.** The two routes
  are not interchangeable for it, and the reason is one row up: the refusal log
  deliberately does not print that rule's digest, because a connection string is
  short and low-entropy enough that its sha256 is walkable back to the password.
  So a digest that would excuse such a file is one somebody computed *from a
  copy of the credential they already hold*, arriving as a bare 64-hex literal
  with no filename attached — a shape review cannot check. The allow-*file*
  route names the path, so the entry says what is being excused. A digest that
  matches a `url-embedded-basic-auth` file is refused with the allowlist set,
  the same way a `registry-auth-token` hit is, and no `CACHE_SCAN_ALLOW_DIGESTS`
  entry can change that.
- **It reaches the content pass only.** The filename, symlink, setuid and
  capability passes take no exceptions; a host refuses those outright, so an
  archive that needs one of them excused is an archive no host would unpack.
- **Every excusal is logged** by name and digest on the run that uses it, so a
  snapshot published with an exception says so in its own log.

What it does *not* have is a second opinion. The host runs no content pass, so an
entry here is the last word on that file. Never add one justified only by "this
hash was in the way": name the package in the comment, and confirm the file is in
that package's *published* tarball rather than something your install produced.
If you cannot say which dependency ships it, you have not finished diagnosing it.

### Once there is more than a handful: `CACHE_SCAN_ALLOW_FILE`

The paragraph above assumes one fixture. A real dependency tree does not stop
there — a `pnpm install` of one production monorepo lands **71** files carrying a
private-key header, 49 of them from `ssh2` alone, which ships a directory of real
published test keys, and a further **40** carrying a `user:password@` URL, every
one of them a placeholder in a package's own documentation (`user:pass`,
`guest:guest`, `${USER}:${PASS}`). A hundred-odd hashes in a YAML scalar is a
list nobody reads, and an allowlist nobody reads is the hole it was meant to
close.

Point at a file instead. Check it in next to the workflow, one digest per line,
each with a comment naming the package:

```yaml
# in BOTH jobs
env:
  CACHE_SCAN_ALLOW_FILE: .github/cache-scan-allow.txt
```

```
# ssh2@1.17.0 test/fixtures — published test keys, in the tarball on npm.
a0b4c0a4...  # ssh2/test/fixtures/https_key.pem
cf327148...  # ssh2/test/fixtures/openssh_new_rsa
```

**The comment is required, not encouraged.** A line holding a digest and nothing
else is refused at startup, by line number. The rule everywhere else here is that
a fixture is excused by the package that ships it and never by the hash alone;
this is the one place that rule can be enforced rather than written down.

Everything the variable guarantees, the file guarantees: full 64-character
digests, the two excusable rules only, the per-rule floors, the content pass
only, every use logged. Two
further refusals are specific to it — a path naming no readable file, and a file
holding nothing but comments. Both would otherwise excuse nothing while reading
exactly like a list that worked, and the symptom is a publish that refuses on
every run for a reason nobody can see.

The file is read at startup, **before the prepare command runs**. The build job's
checkout is writable by the install it is about to launch, so an allowlist parsed
any later is one that install could have extended with a digest of its own.

That is also a precondition the env-var form did not have, and it is on you to
keep: **nothing the untrusted build job produced may land on top of the allowlist
file.** In the workflow above it cannot — `download-artifact` unpacks into
`${{ runner.temp }}`, not the workspace. Point that `path:` at the checkout and
the build job's artifact can overwrite the list the credentialed job is about to
scan with.

Indentation is fine; leading whitespace is stripped before the line is judged.

Both may be set; the entries are unioned. The same "literal in the repository,
never `${{ vars.* }}`" rule applies — a checked-in file is a diff that goes
through review, which is the whole reason to prefer it.

To regenerate the list after a dependency bump, run the install and digest what
the scan would stop on:

```bash
grep -rlaZ -E -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$(pnpm store path)" \
  | xargs -0 -r sha256sum | cut -d' ' -f1 | sort -u
```

Then map each digest back to a package before you paste it in — the store names
files by hash, so `sha256sum` over `node_modules/.pnpm` is what recovers the name
the comment has to carry.

## First run

Run the build phase alone: `CACHE_PREPARE=… CACHE_DRY_RUN=1 bash
scripts/ci/publish-cache-snapshot.sh`. It installs, scans and packs, prints the
size, and uploads nothing — no credential is involved, so it runs on a laptop
with `libcap2-bin` installed (the scan needs `getcap`, and a run that cannot scan
is refused rather than skipped). The size is the number that matters: a snapshot past the pools'
`cache_snapshot_max_bytes` (4 GiB by default, compressed) is refused by every
host, which reads in their logs as *"no snapshot published"* rather than as an
error.

## Verifying it worked

```bash
gcloud storage cat gs://<bucket>/cache/<pool>/current
```

You should not have to. The pools publish `ci_cache_snapshot_age_hours` from
every host boot, and `ensure-alert-policies.sh` installs a policy that pages when
it passes `--cache-stale-hours` (48 by default) — which is what a scheduled
publish that quietly stopped looks like, days before hosts start refusing the
snapshot and running cold. Read `ci_cache_hydrate_verdict` grouped by its label
to see what the hosts actually did with what you published: `scan-refused` there
means this script uploaded an archive the hosts' own scan rejects, and is the one
verdict that points back at the publisher rather than at the pool.

Then boot a host and read `/var/log/ci-runner-startup.log`: a successful hydrate
logs the snapshot name, how many tool caches it moved in, its size, its age, and
how much of the budget it spent. Every failure inside that budget is one line and
a cold first job — the layer fails open, so a broken publish costs cache hits and
never a host that does not come up.

**On a Windows pool the log is the only place to look.** That boot script has no
metric client, so it publishes none of the series above: the verdict is one
`phase 7: cache hydrate verdict: <verdict>` line on the startup script's stdout,
which GCE captures to the host's serial port 1
(`gcloud compute instances get-serial-port-output <host> --project <p> --zone <z>`).
The consequence is worth stating plainly, because it is the failure this document
otherwise tells you the dashboard will catch: a Windows pool whose publish
silently stopped, or whose hosts refuse every snapshot, is invisible in
monitoring and shows up only as jobs that got slower. Check a fresh host's log
after the first publish, and again after any change to the workflow.
