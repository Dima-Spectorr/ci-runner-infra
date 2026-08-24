# `ci-runner-controller`

One control plane for **all** of a repository's runner pools.

## Why not one controller per pool

A repository that wants CI and merge-queue capacity on both platforms needs four
pools. Mergify validates a queued pull request by re-running the same
`pull_request` workflows on a `mergify/merge-queue/<sha>` branch, against the
same `runs-on` labels — at exactly the moment the CI pools are busy with the
next pull requests. That is the stall this exists to remove.

Four pools with a controller each is four controllers sweeping the **same**
repository's run list every tick. That does not divide: at the default 20s poll
it is 720 list calls an hour for one answer, against an installation budget all
four share, and the copy that meets the secondary rate limit blinds the rest.

This controller sweeps GitHub **once** per tick and then ticks each pool against
that one answer.

## Wiring

Each pool stays a `ci-runner-host-pool`, with its own controller turned off, and
hands this module its descriptor. Never write the table by hand — `mig` is a
*generated* name, and a wrong one produces a controller that lists an empty
instance group forever and reports a perfectly healthy, permanently empty pool.

```hcl
module "linux_ci" {
  source            = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-host-pool?ref=v5.51.0"
  manage_controller = false
  # …
}

module "controller" {
  source = "git::https://github.com/Dima-Spectorr/ci-runner-infra.git//modules/ci-runner-controller?ref=v5.51.0"

  name  = "<repo>-controller"
  pools = [module.linux_ci.pool_descriptor, module.windows_ci.pool_descriptor]
  # …github app, network, service account
}
```

The module source must be a **git** source. It reads the decision scripts from
its sibling `ci-runner-host-pool` directory, which is on disk because a
`git::…//modules/x` source clones the whole repository; a registry or archive
source packs one subdirectory and would not carry it.

## Watch this

`ci_pool_table_rejected`. A pool whose row the controller refused is simply
never ticked — it has no series of its own to go absent, and its autoscaler is
`ONLY_UP`, so it holds its last size indefinitely while every other pool on the
dashboard reads healthy. Compare the metric against the `pools_served` output.
