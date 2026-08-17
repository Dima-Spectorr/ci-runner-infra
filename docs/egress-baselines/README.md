# Egress baselines — where each pool is agreed to connect out to

One file per project, `<project-id>.txt`, listing the outbound destinations that
pool is **agreed** to reach. `scripts/ci/egress-destinations.sh` reads the
firewall log, aggregates the window, and reports anything not in here.

## Why a file in the repository and not a monitoring rule

Cloud Monitoring can alert on *more* — more bytes, more connections, more
refusals. It has no notion of *new*, and "new" is the whole question. A warm
runner holds a GCP identity and runs third-party code out of every lockfile it
installs; the connection that matters is the first one to a destination nobody
has ever seen, and it is one connection, at a volume that no threshold
distinguishes from noise.

So novelty is a **diff**, and a diff needs a written-down side. Putting that
side in the repository means adding a destination is a pull request somebody
reads — which is the mechanism. A baseline the tool could update on its own
would agree with whatever happened last night, including the exfiltration.

## The key, and why it is not an IP

```
as:36459|US|443            # ASN 36459 (GitHub), United States, port 443
net:140.82.121.0/24|US|443 # fallback: the log carried no ASN
```

Package registries and GitHub sit behind CDNs whose addresses rotate
constantly. Keyed by address, this file would churn daily and every run would
report a dozen "new" destinations that are the same destination — and a report
that cries wolf is worse than no report, because its silence is what people
come to rely on. Keyed by the owning network, a CDN rotation is one destination
and a rented VPS is a different ASN on its first packet.

The `net:` form is a marked fallback, not an equivalent. It appears when the
firewall rules were logged with `EXCLUDE_ALL_METADATA` (the module sets
`INCLUDE_ALL_METADATA`; see `modules/ci-runner-network`). A baseline written
under one metadata setting will not match a window read under the other, and
the marking is what makes that legible rather than mysterious.

Only **allowed** connections become keys. A refused one never reached anywhere,
and recording it here would put a destination the pool never got to into the
list of destinations it is agreed to reach. Refusals are the other policy's
business: `ci_egress_denied` and the *egress refused* alert in
`scripts/ci/ensure-alert-policies.sh`.

## Seeding a pool's first baseline

There is nothing to diff against until the logs have accumulated, so a freshly
logged pool has every destination new. Let it run a normal week, then:

```bash
scripts/ci/egress-destinations.sh --project <id> --hours 168 --update-baseline
```

**Read the file before committing it.** Seeding is the review — it is the one
moment when somebody looks at the whole list and says yes. Everything after it
is an incremental judgement about one line, which only works if the starting
point was judged too.

## Reading it afterwards

```bash
scripts/ci/egress-destinations.sh --project <id> --fail-on-new
```

- A destination **not** in the baseline is a finding, and `--fail-on-new` exits
  non-zero on it. Either it belongs — add the line in a pull request — or it
  does not, and that is the thing this exists to catch.
- A baseline entry **not seen** in the window is reported and never fails. A
  registry the pool stopped using is a file that needs tidying, not an incident,
  and failing on it would train everyone to ignore the output.
- **No log entries at all** is an error, not a clean run. It means the record is
  not being written — check `firewall_logging` on the pool's
  `ci-runner-network` module — and a gate that reads nothing must never report
  that everything is fine.
