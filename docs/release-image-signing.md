# Release image signing — the shared step

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
| `public-key-pem` | yes | workspace path of the COMMITTED public key |
| `previous-public-key-pem` | no | second committed key, only for a rotation overlap |
| `required` | — | `true`/`false`; anything else fails |

Outputs: `armed` (`true` when it signed) and `signed` (`true` only when every
digest verified).

## Behaviour

1. **Decide.** Unconfigured (none of the five signing inputs and the PEM set)
   and not required: a `::notice::`, `armed=false`, nothing else runs.
   Partially configured and not required: a `::warning::`, `armed=false`.
   Required and anything missing: the step FAILS. Configured: every input is
   shape-checked, every ref must be digest-pinned (a tag is refused), the PEM
   must exist — all before a credential is minted.
2. **Authenticate** with `google-github-actions/auth` (pinned by commit) as
   the signer through the provider. The caller's job needs
   `permissions: id-token: write`.
3. **Sign.** `gcloud beta container binauthz attestations sign-and-create`
   per digest, billed to the attestor's project. `ALREADY_EXISTS` (a re-run) is
   tolerated, because step 4 decides whether it counts.
4. **Verify.** Read every attestation back and check, with `openssl`, that a
   signature over a payload naming THAT digest verifies against the committed
   PEM. A missing attestation, a wrong key or a payload naming another digest
   fails the step, so `publish` never names an unverified digest.

The job needs `gcloud` with the `beta` component, `python3` and `openssl`
(GitHub-hosted Ubuntu has all three). After the action, the job's Google
credential IS the signer: call it last in its job, or re-authenticate.

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

The action is versioned with this repository: it first ships in the release
whose `VERSION` is `v5.113.0`, and every later release carries it. Pin it the
way the merge lane is pinned (`docs/merge-lane.md`): to the **commit** of a
release tag, with the tag as a comment, because `check-action-pins.sh` (PIN1/PIN2)
rejects a tag and requires the comment. Release tags are annotated, so
dereference the tag object to its commit:

```bash
TAG_OBJ=$(gh api repos/Dima-Spectorr/ci-runner-infra/git/ref/tags/v5.113.0 --jq .object.sha)
gh api "repos/Dima-Spectorr/ci-runner-infra/git/tags/$TAG_OBJ" --jq .object.sha
```

then write `uses: <that path>@<40-char commit> # v5.113.0` on the step.

**Upgrading** is moving that pin. Dependabot's `github-actions` ecosystem
rewrites the sha and the comment together; review the diff of
`.github/actions/release-image-signing/` between the two tags, because this
code runs holding the product's signing identity. A change to the action's
inputs is a minor release; a change that a caller must react to (a renamed or
newly required input) is called out in the release notes.

## Test

`scripts/ci/release-image-signing.selftest.sh` runs in this repository's CI
(`shell-infra`). It runs the action's script against a stub `gcloud` that signs
with throwaway EC P-256 keys, so the verify pass does real `openssl` checks:
a good signature passes; a wrong key, a payload naming another digest, a
missing attestation, a `sign-and-create` error, and a missing input when
required each fail; unconfigured and not required is a notice with no
`gcloud` call.
