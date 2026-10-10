# Release image signing — the shared step

> **v5.113.0 is DO-NOT-ADOPT. Use v5.114.0 or later.** v5.113.0 shipped this
> action before its security review: its auth step wrote a credentials file
> into the workspace and exported `GOOGLE_*` variables, so every later step of
> the caller's job ran as the release signer, and it did not require the
> verifying key to be committed. v5.114.0 is the first release to carry the
> fixes below. A pin to v5.113.0's commit must move.
>
> **v5.114.0 and later are fine to adopt; v5.115.0 is recommended.** v5.115.0
> adds two hardenings from the security re-review, neither of which a caller
> has to react to: the verify pass now checks against the key's COMMITTED
> content (`git show HEAD:<path>`) and refuses a key that a step before the
> action changed in the working tree, and the signer's access token lives ten
> minutes (`access_token_lifetime: 600s`) instead of the default hour.

`.github/actions/release-image-signing/` is the one step every Specaria
product's release workflow calls to sign its released image digests and prove
the signatures. It replaces the per-product copies (Apigee-Portal's
*Decide release signing* / *Attest released image digests* and its
`sign-and-attest-images.sh`), so every product authenticates, signs and
verifies the same way and fails closed the same way.

**Onboarding a product** — the signing-project map entry, the admin apply, the
committed public key, the repository Variables, the first signed release and
arming — is documented in ONE place, the platform contract:
Specaria-Platform `docs/for-products/release-image-signing.md`. This page is
the action's reference: what it takes, what it does, how to pin and upgrade it.

## Why a composite action and not a reusable workflow

Each product's signer is reachable only through its own Workload Identity
provider (Specaria-Platform
`infra/terraform/customer/specaria/gcp-image-signing/signing.tf`,
`release_token_condition`), whose attribute condition is:

```
assertion.repository_id == '<id>'
&& assertion.repository_owner_id == '<owner id>'
&& assertion.job_workflow_ref.startsWith('<owner>/<repo>/<release_workflow>@refs/tags/v')
&& assertion.ref.matches('^refs/tags/v[0-9]+[.][0-9]+[.][0-9]+(-beta[.][0-9]+)?$')
```

A job inside a reusable workflow carries the CALLEE's `job_workflow_ref`
(`<owner>/ci-runner-infra/.github/workflows/<file>@<ref>`), so the provider
would refuse its token — and widening the condition to accept it would let any
repository that calls the shared workflow reach a product's signer. A composite
action runs as steps of the caller's own job, so `job_workflow_ref` stays the
product's `release.yml` on its own version tag and the condition stays exactly
as it is. The same reason makes the action NOT open a job of its own.

## Inputs

| Input | Required when armed | Meaning |
|---|---|---|
| `digests` | one of the two | `repo/name@sha256:<64 hex>` refs, space- or newline-separated |
| `digests-file` | one of the two | a file of such refs, one per line (`#` comments allowed) |
| `expected-count` | no | fail unless exactly this many refs were given |
| `wif-provider` | yes | the product's release-signing provider resource name |
| `signer-sa` | yes | the product's signer service account email |
| `attestor` | yes | bare name, or `projects/<p>/attestors/<n>` |
| `attestor-project` | unless `attestor` is qualified | the signing project; never defaulted to the build project |
| `key-version` | yes | full KMS `.../cryptoKeyVersions/<n>` name |
| `public-key-pem` | yes | workspace path of the COMMITTED (git-tracked) EC P-256 public key |
| `previous-public-key-pem` | no | second committed key, only for a rotation overlap |
| `required` | — | `true`/`false`; anything else fails |

Every value is matched as a WHOLE string, and a value containing a newline is
refused: no input of this action can legitimately hold one. The attestor name
(lowercase letters, digits, `-`, `_`) and the attestor project (a project id)
are shape-checked like the provider, signer and key version.

Outputs: `armed` (`true` when it signed) and `signed` (`true` only when every
digest verified).

## Behaviour

1. **Decide.** Unconfigured (none of the five signing inputs and the PEM set)
   and not required: a `::notice::`, `armed=false`, nothing else runs.
   Partially configured and not required: a `::warning::`, `armed=false`.
   Required and anything missing: the step FAILS. Configured: every input is
   shape-checked, every ref must be digest-pinned (a tag is refused), and each
   PEM must exist, be committed at HEAD, be unchanged in the working tree and
   be an EC P-256 key — all before a credential is minted.
2. **Authenticate** with `google-github-actions/auth` (pinned by commit) as
   the signer through the provider, minting an access token only, valid for
   ten minutes (`access_token_lifetime: 600s`).
   The caller's job needs `permissions: id-token: write`.
3. **Sign.** `gcloud beta container binauthz attestations sign-and-create`
   per digest, with `--project` explicit and billed to the attestor's project.
   `ALREADY_EXISTS` (a re-run) is tolerated, because step 4 decides whether it
   counts.
4. **Verify.** Read every attestation back and check, with `openssl`, that a
   signature over a payload naming THAT digest verifies against the committed
   PEM — read from HEAD with `git show`, never from the working tree. A missing attestation, a failed `attestations list`, a wrong key
   (including an attestation that already existed, signed by another key) or a
   payload naming another digest fails the step, so `publish` never names an
   unverified digest.

The job needs `gcloud` with the `beta` component, `python3`, `openssl` and
`git` (GitHub-hosted Ubuntu has all four), and the repository checked out.

## How the signer's token is handled

The signer's credential does not outlive the action, and no other step of the
caller's job ever holds it.

- The auth step runs with `token_format: access_token`,
  `access_token_lifetime: 600s`, `create_credentials_file: false` and
  `export_environment_variables: false`.
  So there is **no `gha-creds-*.json` credentials file** in the workspace, and
  **no `GOOGLE_*` or `CLOUDSDK_*` variable** is written to `GITHUB_ENV`.
- The token output is referenced ONCE, in the sign step's `env:`. The script
  writes it to a `0600` file in that step's own temp directory, unsets the
  variable, hands the file to `gcloud` through
  `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE`, and removes the directory on exit — pass
  or fail.
- Steps after the action keep whatever Google identity they had before it. If
  a later step needs a credential, it authenticates for itself.

## The signing key

- The KMS key must be **`EC_SIGN_P256_SHA256`** — the algorithm the platform
  provisions. The script refuses a `public-key-pem` that is not an EC P-256
  key (an RSA key, for example) by name, before it signs anything.
- The public key PEM must be **committed: tracked by git** in the caller's
  repository. A file the release run generated or downloaded would let the run
  vouch for itself, so an untracked PEM fails the step. Tracked is not
  enough: an earlier step of the release job could overwrite the file, so the
  PEM must also be in HEAD and unchanged from it (`git diff --quiet HEAD`),
  and the verify pass checks signatures against `git show HEAD:<path>`, never
  the working-tree file.
- **Rotation.** Commit the new key, point `public-key-pem` at it and
  `previous-public-key-pem` at the old one for the overlap window only. Once
  every release that customers may still admit is signed by the new key,
  **remove the previous key**: delete `previous-public-key-pem` from the step
  and the old PEM from the repository. A previous key left in place is a
  second key the verify pass keeps trusting indefinitely.

## Calling it

The standard Variable names for a product onboarding now (an existing product
may keep its own names and map them in `with:`):

```yaml
jobs:
  build:
    permissions:
      contents: read
      id-token: write
    steps:
      # ...build and push; write the digest-pinned refs to digests.txt...
      - name: Sign released images
        id: signing
        uses: Dima-Spectorr/ci-runner-infra/.github/actions/release-image-signing # + "@<commit> # <tag>", see Pinning
        with:
          digests-file: digests.txt
          expected-count: '5'
          wif-provider: ${{ vars.RELEASE_SIGNING_WIF_PROVIDER }}
          signer-sa: ${{ vars.RELEASE_SIGNING_SA }}
          attestor: ${{ vars.RELEASE_SIGNING_ATTESTOR }}
          attestor-project: ${{ vars.RELEASE_SIGNING_ATTESTOR_PROJECT }}
          key-version: ${{ vars.RELEASE_SIGNING_KEY_VERSION }}
          public-key-pem: infra/binauthz/specaria-image-signing-<product>-v1.pub.pem
          # Stable tags may not publish unsigned once the product is armed;
          # a beta tag only warns.
          required: ${{ vars.RELEASE_SIGNING_REQUIRED == 'true' && !contains(github.ref_name, '-') }}
```

`steps.signing.outputs.signed` is what the publish summary should show.

## Pinning, versioning and upgrading

The action is versioned with this repository. **Adopt it at `v5.114.0` or
later (`v5.115.0` recommended); never at `v5.113.0`** (see the note at the
top). Pin it the way the
merge lane is pinned (`docs/merge-lane.md`): to the **commit** of a release
tag, with the tag as a comment, because `check-action-pins.sh` (PIN1/PIN2)
rejects a tag and requires the comment. Release tags are annotated, so
dereference the tag object to its commit:

```bash
TAG_OBJ=$(gh api repos/Dima-Spectorr/ci-runner-infra/git/ref/tags/v5.115.0 --jq .object.sha)
gh api "repos/Dima-Spectorr/ci-runner-infra/git/tags/$TAG_OBJ" --jq .object.sha
```

then write `uses: <that path>@<40-char commit> # v5.115.0` on the step.

**Upgrading** is moving that pin. Dependabot's `github-actions` ecosystem
rewrites the sha and the comment together; review the diff of
`.github/actions/release-image-signing/` between the two tags, because this
code runs holding the product's signing identity. A change to the action's
inputs is a minor release; a change that a caller must react to (a renamed or
newly required input) is called out in the release notes.

## Test

`scripts/ci/release-image-signing.selftest.sh` runs in this repository's CI
(`shell-infra`). It runs the action's script inside a throwaway git repository
that tracks the test keys, against a stub `gcloud` that signs with throwaway
EC P-256 keys, so the verify pass does real `openssl` checks:

- passes: a good signature; a re-run that finds the attestation already there;
  a fully named attestor; a key-rotation overlap.
- fails: a wrong key; an `ALREADY_EXISTS` attestation signed by the wrong key;
  a payload naming another digest; a missing attestation; `attestations list`
  exiting 1; a `sign-and-create` error; a missing input when required; a
  missing access token; an untracked PEM; a tracked PEM edited in the
  working tree (current or previous key); a PEM staged but never committed;
  an RSA PEM; a newline in a value; a
  malformed attestor name or project.
- the token reaches `gcloud` only as a `0600` file, never as an environment
  variable, and the file is gone after the step.
- the action wiring: no `${{ }}` in any `run:` body (a fixture proves the scan
  catches one inside a `run: |` block), the four auth settings above, and the
  token output referenced exactly once.

Unconfigured and not required is a notice with no `gcloud` call.
