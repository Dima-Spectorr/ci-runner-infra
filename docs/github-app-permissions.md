# The GitHub App the fleet runs as

Every pool in the fleet authenticates to GitHub as **one GitHub App**, not as a
PAT and not as a per-repository token. This page is the whole answer to "which
permissions does it need, who can grant them, and how do I know it worked" —
written because the answer previously existed only as a sentence in an
onboarding checklist, and because **every permission on this list fails
silently**. Not one of them fails an apply, fails a job, or turns a check red.

Two facts shape everything below:

* **A permission grant covers an installation, not a repository.** One App
  serves every repository selected in a given installation, so the grant is
  done once and lands on all of them — and a permission nobody noticed was
  missing was missing on all of them too. **The fleet is not one App.** There
  is more than one, so "we granted it" is only ever true of the installation it
  was granted on: check each root's own `github_app_id` /
  `github_installation_id` in its `terraform.tfvars` before assuming a repo is
  covered by a grant made elsewhere.
* **A permission added to an App is not granted until the installation accepts
  it.** GitHub treats the edit as a *request*. Until an owner approves it, the
  App behaves in every respect as though the permission had never been added.
  This is the single most common way this goes wrong: somebody edits the App,
  sees the new dropdown saved, and reasonably concludes they are done.

## What it needs, and what each one buys

| Permission | Level | The call that needs it | Without it |
|---|---|---|---|
| **Metadata** | Read | mandatory for every App | nothing works |
| **Administration** | Read & write | `POST repos/{repo}/actions/runners/registration-token`, `GET repos/{repo}/actions/runners` | **hosts cannot register.** The one permission here that fails loudly — a host boots, cannot get a token, and the pool serves nothing |
| **Actions** | Read | `GET repos/{repo}/actions/runs`, `.../runs/{id}/jobs` | the controller sees no demand, publishes none, and the pool never scales out. Reads on every chart as a quiet repository |
| **Checks** | Read | `GET repos/{repo}/commits/{sha}/check-runs` | the merge-queue **parking detector** can never report. Signalled: `ci_parked_sweep_denied` non-zero, log `parked sweep: DENIED`, `parkeddenied` alert after 30 min |
| **Pull requests** | Read | `GET repos/{repo}/pulls?state=open` | same detector, one step earlier — log `parked sweep: cannot list open pull requests` |
| **Contents** | Read | `GET repos/{repo}/contents/{path}` | the merge-queue pool **cannot read `.mergify.yml`** and cannot derive its own size. Fails open: it keeps the Terraform `max_hosts` you typed, forever, and says so only in a log line |

`Administration: read & write` is the level that makes some reviewers stop. It
is what GitHub requires to mint a self-hosted-runner registration token; there
is no narrower scope for it. It is also the reason the App private key never
leaves Secret Manager and is readable only by the host service account, never
by the account job code runs as — the identity split in
[`modules/ci-runner-identity`](../modules/ci-runner-identity/main.tf), enforced
in every consumer's CI by `scripts/ci/check-ci-runner-identity-split.sh`.

## Who grants it

Two different people may be involved, and the split is what makes this take
days instead of minutes:

1. **The App owner** — whoever owns the App itself. For an App owned by a
   personal account, that is only that account: there is no second maintainer
   and no team. For an org-owned App, an org owner. **This is the only party
   who can change what the App asks for.**
2. **The installation owner** — whoever owns the account the App is installed
   on (the account holding the repositories). **This is the only party who can
   accept a change**, and it is a distinct step from the first even when it is
   the same human.

In this fleet both are the account that owns the repositories, which is a
personal account — so the two roles collapse to one person, and the practical
consequence is a bus factor of one on every permission the fleet depends on.
Say so out loud when planning: nobody else can perform either step.

**To find out which App you are looking at**, take the numeric `github_app_id`
out of the consumer's `terraform.tfvars` and the `github_installation_id` next
to it. The installation's configuration page is
`https://github.com/settings/installations/<installation_id>` for a personal
account (Settings → Applications → Installed GitHub Apps → Configure), and it
names and links the App.

## How to grant it

**Step 1 — the App owner edits the App.**

Profile picture → **Settings** (or, for an org-owned App, the org's Settings) →
**Developer settings** → **GitHub Apps** → the App → **Edit** → **Permissions &
events** → Repository permissions → set the dropdown → **Save changes**.

Use the "Add a note to users" box. The note is what the approver reads in the
notification email, and "the merge-queue pool needs to read `.mergify.yml` to
size itself" is a far better prompt to act on than a bare permission name.

**Step 2 — every installation owner accepts it.** GitHub emails each org owner
or user with the request; the request also appears on the installation's own
configuration page (the URL above). Approve it there.

Nothing takes effect until step 2 completes, on every installation. If the App
is installed on more than one account, each one accepts separately.

**Step 3 — nothing.** No apply, no restart, no redeploy. The controller mints a
fresh installation token routinely and the next one carries the new permission;
`Contents: read` starts working within one read interval (300 s), the parked
sweep within one sweep.

## How to verify it actually landed

Three ways, cheapest first. Prefer the first — it verifies the thing you
actually care about, which is what the *controller* can do, not what a settings
page claims.

**1. Read the controller's log.** The controller logs every denial with the
status it got back. The controller VM's name is its MIG's name plus a generated
suffix, so resolve it first —
`gcloud compute instance-groups managed list-instances <mig> --region=<region>
--project=<project>` — and then:

```bash
gcloud compute ssh <controller-instance> --zone=<zone> --project=<project> \
  --tunnel-through-iap --command 'journalctl -u ci-controller -n 300 --no-pager'
```

Look for `parked sweep: DENIED`, or `mergify config could not be fetched (api
status 403)`. Both name the status, so a 403 is distinguishable from a
transient 5xx by reading the line. Silence on both is the pass.

**2. Read the metrics.** Every one of these is a fleet dashboard series:

* `ci_queue_config_age_seconds` — **the `Contents: read` indicator.** Healthy is
  under 300. Climbing without bound means the read is failing and the ceiling
  in force is that old. `-1` means it has never succeeded once, which is what a
  pool that has never had the permission publishes from its first tick.
* `ci_parked_sweep_denied` — non-zero is `checks: read` missing.
* `ci_demand` flat at zero on a repository that is plainly busy — `Actions:
  read`.

There is **no alert policy on `ci_queue_config_age_seconds`** today; the
`parkeddenied` alert has no counterpart here. Until there is, a missing
`Contents: read` is found by looking, not by being told.

**3. Ask GitHub, if you hold the private key.** The permissions an installation
actually has come back on `GET /app/installations/{installation_id}`, which
needs a JWT signed with the App private key — a PAT gets `401 A JSON web token
could not be decoded`, and no `gh` login of any kind will answer it. The key is
in Secret Manager and reading it out to a laptop to answer a question is a
worse trade than reading the log above. Do this only when you are already
holding the key for another reason, and never write it to disk.

## When it breaks, this is what it looks like

| Symptom | Cause |
|---|---|
| Hosts boot and no runner appears in the repository's runner list | `Administration` missing or read-only |
| Pool never scales out; `ci_demand` is flat zero while jobs queue | `Actions: read` |
| `ci_parked_sweep_denied` non-zero, `parkeddenied` alert | `Checks: read` |
| Merge-queue pool stuck at exactly `merge_queue_max_hosts`, or at whatever it derived days ago; `ci_queue_config_age_seconds` climbing | `Contents: read` |
| Any of the above, immediately after somebody "granted the permission" | the installation never accepted it — step 2 |

The last row is worth its own sentence, because it is the one that costs an
afternoon: **a pending permission and an ungranted permission are the same
permission.** There is no partial state, no warning, and no difference in
behaviour. Check the installation page before you check anything else.
