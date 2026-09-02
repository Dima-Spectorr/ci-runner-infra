# ci-runner-host-pool -- Windows host boot.
#
# The Linux counterpart is `host-startup.sh`, and the first paragraph of that
# file applies here word for word: this script INSTALLS NOTHING. The runner
# agent, the build toolchains and the warm caches are in the golden image
# (packer/ci-host-image-win.pkr.hcl). A pool that installs at boot has
# re-invented the per-job cost it exists to delete -- which is precisely what
# the retired one-VM-per-job Windows pool did.
#
# Agents are NOT --ephemeral, for the same reason they are not on Linux: the
# host stays hot and keeps serving. What differs is where the isolation comes
# from. On Linux each slot gets its own user, its own rootless container daemon
# and its own network namespace. On Windows a slot gets its own LOCAL ACCOUNT,
# and that is the whole boundary (see section 4 of docs/adr-windows-pool.md for
# what that does and does not buy).
#
# THIS FILE IS DELIVERED IN PHASES, AND THE ORDER IS THE SAFETY PROPERTY
#
#   phase 0  preflight, image assertion, and the beacon BEFORE anything else
#   phase 1  slot accounts, logon rights, ACLs, per-slot TEMP
#   phase 2  the metadata fence                                (DELETED, see below)
#   phase 3  the job credential broker
#   phase 4  the per-job slot reset: hooks, state, and the SYSTEM service
#   phase 7  the per-slot dependency cache                    (fails OPEN)
#   phase 6  the boot probe, run as a slot account
#   phase 4b the profile templates, captured once the probe has made the profiles
#   phase 5  agent registration as a service
#
# Phase 6 RUNS BEFORE PHASE 5, and the numbers are the order they were written
# in, not the order they execute in. A host proves the slot boundary before it
# accepts a job or it proves nothing worth having: an agent registered first is
# an agent that can be handed work while the proof is still running.
#
# THE REGISTRATION TOKEN IS READ ONCE, AND A HOST THAT CANNOT GET ONE BLOCKS
#
# The controller mints the repository registration token, writes it to this
# instance's `ci-registration-token` metadata key, and DELETES that key the
# moment GitHub reports any of this host's agents registered -- `partial`, not
# only `present`. Two host-side obligations follow from that, and the controller
# cannot check either one:
#
#   (a) ONE read, above the slot loop. A per-slot read on a two-slot host reads
#       the key for slot 1, registers it, the controller's delete fires, and
#       slot 2 reads nothing -- a host stuck at half capacity with no error
#       anywhere. The single read is what makes the `partial` expiry safe.
#
#   (b) After the key is gone, a reboot LOGS AND BLOCKS. Windows hosts reboot for
#       updates, so this is ordinary behaviour here rather than an edge case: the
#       key was deleted, the controller will not mint a second, and the honest
#       outcome is a host that says so and registers nothing, so the register-
#       grace drain reclaims it and the MIG replaces it. Registering with an
#       empty token instead produces an agent-side failure that reads like a
#       GitHub outage.
#
# THERE IS NO PHASE 2, AND THERE WILL NOT BE ONE
#
# Section 3A of docs/adr-windows-pool.md deletes the metadata fence rather than
# deferring it: Windows Firewall gives an explicit block rule precedence over
# every conflicting allow rule, supports no administrator-assigned ordering, and
# offers no per-principal outbound filter that works without IPsec the metadata
# server does not speak. A host-wide block installs cleanly and takes the guest
# agent, the beacon and this broker down with the slot accounts. The safety
# property moved into IAM instead -- a Windows pool's host account is reduced
# until the token job code can mint is worth only what the broker was going to
# hand it anyway -- and that reduction is PR 4b's, not this file's.
#
# The consequence for THIS file is a rule, and it is the one the self-test
# guards: no credential of any kind is written to instance metadata or to guest
# attributes, and no `New-NetFirewallRule` appears anywhere in it. A fence
# reintroduced by a later edit would review as working and enforce the opposite
# of what it claims.
#
# Phase 1 builds the boundary; phases 3 and 4 build what job code is given
# INSIDE it -- a weaker credential, and a guarantee that it does not outlive the
# job. Phase 6 is the first thing that SPENDS a slot credential, and it spends it
# on proving the boundary rather than on serving a job; phase 5 spends it on the
# agents.
#
# Every phase either succeeds or the host registers nothing. There is no partial
# host: one that came up without its broker turns every deploy step into a
# confusing auth failure, and one that came up without its reset hands the next
# pull request everything the last one left in the profile.
#
# WHY THE BEACON IS PHASE 0 AND NOT PHASE 5
#
# There must be no instant in this host's life at which a `Runner.Worker.exe`
# could exist without a publisher able to see it, and the cheapest way to
# guarantee that is to start the publisher before anything that could ever spawn
# one. (The second reason this file used to give -- that the phase-2 fence
# exempted the beacon by service SID, and a SID that does not exist yet cannot be
# exempted -- died with the fence. Section 3A, again.)

[CmdletBinding()]
param()

# Strict mode and the error preference are set at the entry point at the bottom,
# not here. Setting them at script scope makes dot-sourcing this file
# RECONFIGURE its host, and the host is Pester: strict mode leaking into the
# test runner's own scope chain aborts the whole container before a single test
# runs (pester/pester#2669). Dot-sourceable WITHOUT side effects is the file's
# contract, and two preference variables are side effects.

$script:CiRoot = 'C:\ci'
$script:SlotRoot = 'C:\ci\slots'
$script:BinRoot = 'C:\ci\bin'
$script:LogPath = 'C:\ci\ci-host.log'
$script:ImageMarker = 'C:\ci\image-version.txt'
$script:MetadataRoot = 'http://169.254.169.254/computeMetadata/v1'

# The service shim is an IMAGE component, not something this script installs.
# A PowerShell script cannot be a Windows service on its own: the service
# control manager expects SERVICE_RUNNING to be reported within its start
# timeout, `powershell.exe -File` never reports it, and the SCM kills the
# process. The shim is the thing that answers the SCM and supervises the script.
$script:ServiceShim = 'C:\ci\bin\ci-service-shim.exe'
$script:BeaconServiceName = 'ci-beacon'
$script:BrokerServiceName = 'ci-job-broker'

# The interpreter the broker runs under is an IMAGE component too, at a path this
# module fixes rather than discovers. Resolving `python.exe` through PATH would
# make the broker's identity depend on whatever the image last installed, and
# PATH is the one input to a service start that a future image change can alter
# without anybody reading this file.
$script:PythonExe = 'C:\ci\bin\python\python.exe'
$script:BrokerScript = 'C:\ci\bin\job-metadata-broker.py'

# The hooks do NOT live under C:\ci\bin. That directory is locked to SYSTEM and
# Administrators with no slot ACE at all (phase 1), and a hook a slot cannot read
# is a hook that fails every job on the host. They get their own directory with
# their own ACL: SYSTEM and Administrators full, every slot read-and-execute.
#
# TWO files, because the runner does not tell a hook which end of the job it is
# running at: the same path in both variables would be one script guessing from
# an environment a job can set. The two ends do different things -- see
# Get-JobHookScript -- and the difference is a gate versus a reset, so guessing
# is not an option.
$script:JobHookRoot = 'C:\ci\job-hooks'
$script:JobHookStartedPath = 'C:\ci\job-hooks\slot-reset-started.ps1'
$script:JobHookCompletedPath = 'C:\ci\job-hooks\slot-reset-completed.ps1'

# --- the per-job slot reset (phase 4) -----------------------------------------
#
# The Windows spelling of Linux's slot reset, and the ADR section it implements
# (docs/adr-windows-pool.md, phase 4, revised by #232) carries the reasoning. The
# three constants that ARE the security boundary:
#
#   $script:StateRoot\<i>           SYSTEM and Administrators full, the slot
#                                   READ. The `clean` marker lives here, so a
#                                   slot cannot write itself a clean verdict.
#   $script:StateRoot\<i>\request   the same, plus WRITE for ci-s<i> alone. This
#                                   is the whole request channel: which slot is
#                                   being reset is decided by the directory the
#                                   request appeared in, never by anything
#                                   inside it.
#   $script:ProfileTemplateRoot\<i> SYSTEM and Administrators only, no slot ACE.
#                                   A slot that could write its own template
#                                   would be handing every later job on that
#                                   slot whatever it left there.
$script:StateRoot = 'C:\ci\state'
$script:ProfileTemplateRoot = 'C:\ci\profile-template'
$script:SlotResetRoot = 'C:\ci\slot-reset'
$script:SlotResetScriptPath = 'C:\ci\slot-reset\ci-slot-reset.ps1'
$script:SlotResetConfigPath = 'C:\ci\slot-reset\ci-slot-reset.xml'
$script:SlotResetServiceName = 'ci-slot-reset'

# How long the STARTED hook waits for a verdict before failing the job, and how
# often it looks. Bounded like every other wait in this file: a reset service
# that has died must fail the job it cannot vouch for, not hang the agent on it.
$script:SlotResetWaitSeconds = 300
$script:SlotResetPollSeconds = 2

# The wall-clock bound on the CAPTURE at boot. Bounded for the reason phase 7's
# copies are: the call operator cannot be asked to give up once the child is
# running, so a wedged mirror is a host that never registers. Nothing is waiting
# on this one, so it is generous rather than tight -- the bound is there to end a
# hang, not to police a duration.
$script:ProfileTemplateSeconds = 600

# The bound on every RESTORE afterwards, and it is deliberately much shorter than
# the capture's. THE RESET SERVICE SERVES EVERY SLOT FROM ONE SERIAL LOOP, so
# this bound is not just how long one slot's own reset may take -- it is how long
# a DIFFERENT slot's gate sits behind it. At the capture's 600 s a single slow
# mirror would outlast $SlotResetWaitSeconds and fail a job on a healthy slot,
# which is the one failure this whole layer is supposed to make impossible.
# Quiesce (30) + hive (30) + this must leave room inside the hook's wait.
$script:SlotResetCopySeconds = 120

# --- the dependency cache -----------------------------------------------------
#
# The Windows counterpart of host-startup.sh's CACHE_MASTER -> CACHE_SLOTS split,
# and the two trees mean exactly what they mean there:
#
#   $script:CacheMaster (C:\ci-cache) is baked by the image, owned by SYSTEM and
#     Administrators, and READ-AND-EXECUTE to every slot account. No slot can
#     write anywhere in it.
#   $script:CacheSlots\<idx> is one writable cache per slot, COPIED from the
#     master at boot and reachable only by that slot.
#
# A tree several slot accounts can write is a channel by which one job hands the
# next one code to run -- `npx` executes out of the npm cache, NuGet does not
# re-verify a package already in the global-packages folder, pip does not re-hash
# a cached wheel. That is why the master is read-only and the copy is per slot.
#
# WHY A FULL COPY, AND NOT A JUNCTION OR A HARDLINK OR A CLONE
#
# This is the choice issue #150 calls the substance of the work, so all three
# rejected options are recorded rather than left to be re-derived:
#
#   * A JUNCTION (or a symlink) from each slot to the master is one tree wearing
#     K names. Either the master stays read-only, in which case every package
#     manager fails on its first write into what it believes is its own cache, or
#     it is made writable and every slot is writing the tree every other slot
#     reads -- the cross-slot channel above, with extra steps.
#   * NTFS HARDLINKS are the Windows shape of the `cp -al` idea Linux rejected,
#     and they fail here for a harder reason. A file's security descriptor lives
#     on its MFT record, not on the directory entry, so every hardlink to a file
#     SHARES ONE ACL. A slot's "own" copy would carry the master's ACL: it cannot
#     be granted write for that slot alone, and granting it at all grants it to
#     every slot at once. On Linux the equivalent failure was a sysctl
#     (fs.protected_hardlinks) that could in principle be turned off; here there
#     is no per-link ACL to fix, so there is nothing to trade away.
#   * BLOCK CLONING (the copy-on-write answer) is a ReFS feature. This module
#     provisions one 200 GB NTFS boot disk and no second volume, and NTFS has no
#     block cloning at any version. Reaching for it would mean provisioning and
#     formatting a second disk per host, which is a larger change than the saving
#     it buys on a tree measured in single-digit gigabytes.
#
# So each slot gets its own bytes, and every tool then sees what it sees on an
# ordinary single-user machine: its own cache, owned by the account running it,
# with no permission special case anywhere. The price is disk, K copies of it,
# which is why Test-CacheSeedAffordable exists and why a slot that would not fit
# runs cold instead of filling the volume out from under the jobs.
$script:CacheMaster = 'C:\ci-cache'
$script:CacheSlots = 'C:\ci\cache'

# One subdirectory per tool, named for the tool rather than for the language, and
# deliberately the SAME list as CACHE_DIRS in host-startup.sh -- a tree lifted off
# a Linux host and a tree lifted off a Windows one describe themselves the same
# way, and the two boot scripts can be diffed.
$script:CacheDirs = @('npm', 'yarn', 'pnpm-store', 'go-mod', 'pip', 'uv', 'm2', 'nuget', 'composer')

# How much of the volume must still be free AFTER a slot's copy for that copy to
# happen at all. The host disk is 200 GB and the Windows image is the large part
# of it; what is left carries K job workspaces, K per-slot TEMPs and now K cache
# copies. Filling the volume does not slow a job down, it fails it -- and it fails
# every OTHER slot's job on the host at the same time, which a cold cache never
# does. So the floor is checked before EACH slot's copy rather than once for the
# host: the slots that fit are seeded and the rest run cold, instead of the whole
# pool running cold because the last one would not have fitted.
$script:CacheFreeFloorBytes = 25GB

# HOW LONG PHASE 7 MAY SPEND BEFORE IT GIVES UP AND LETS THE HOST REGISTER.
#
# Every expensive thing in this phase -- the recursive scan of the master, the
# two icacls tree walks, one robocopy per tool per slot -- takes time that is a
# property of the IMAGE rather than of this code, and all of it is spent BEFORE
# phase 5 registers an agent. A big enough cache therefore stops being slow and
# starts being invisible: drain_decision.sh calls an agent-less host never
# registered once the grace expires, the replacement is built from the same
# image, and the pool rebuilds hosts forever over a cache that was only large.
#
# So the seeding is budgeted. When the budget is gone the remaining slots and
# tools get empty directories -- the same cold cache every other phase-7 refusal
# produces -- and the boot moves on. It is deliberately well under the
# registration grace, because phase 7 is not the only thing that still has to
# happen.
$script:CacheSeedBudgetSeconds = 420

# --- the snapshot the image did not bake -------------------------------------
#
# The Windows half of host-startup.sh's hydrate_shared_cache(). The baked master
# is as old as the image, and a pool only ever scales out under load -- so every
# new host is handed the coldest cache in the fleet at exactly the moment the
# queue that caused the scale-out needs it warmest. The snapshot closes that gap:
# a regularly published tarball of this same tree, unpacked over the baked one at
# boot, before anything is sealed or copied.
#
# THE SAME FOUR PROPERTIES THE LINUX SIDE IS BUILT ON, AND EACH IS LOAD-BEARING.
#
# 1. READ ONLY, ALWAYS. This host never writes to the bucket. Its service account
#    holds `roles/storage.objectViewer` conditioned on this pool's own prefix --
#    no create, no delete, no other pool -- and that is the whole reason a host
#    may consume a snapshot at all. A host executes job code; a host that could
#    publish would let whatever one job left in a cache become the starting cache
#    of every later host in the pool, which is the cross-slot channel the
#    per-slot copy closes, re-opened across hosts and across time.
#
# 2. BOUNDED, THEN ABANDONED. Everything here runs against one deadline. A slow
#    or missing snapshot costs the FIRST job on this host a cold cache; a host
#    that waits on it costs the pool a host, and the pool answers a missing host
#    by queueing jobs. Every failure below is logged and survived.
#
# 3. AGED OUT HERE TOO. The bucket deletes snapshots at its own age bound and
#    this refuses one older than its own limit. Two bounds because they fail
#    differently: the bucket's holds if this script is broken, this one holds if
#    the lifecycle rule is edited away in the console -- and lifecycle deletion is
#    asynchronous, so the bucket's bound alone is soft by up to a day.
#
# 4. INSPECTED BEFORE IT IS TRUSTED. What arrives is untrusted build input that
#    passed through no image-build gate, so it goes through Get-CacheHostileReason
#    in a staging tree before anything reaches C:\ci-cache -- the same scan
#    Protect-CacheMaster runs, on content no reviewed build step stands in front
#    of.
#
# 5. REPORTED. The four failure modes above are all silent by design -- the layer
#    fails open, so a pool that stopped hydrating and a pool hydrating perfectly
#    both look like "jobs are a bit slow". Publish-CacheTelemetry sends the same
#    five series host-startup.sh does, under the same names, on the same
#    `generic_node` resource, so one alert policy and one dashboard cover both
#    kinds of pool. See the telemetry section below Write-BootLog.
$script:CacheStage = 'C:\ci-cache.staging'
$script:CacheDownload = 'C:\ci-cache.download'

# What the hydrate measured, for the telemetry to publish after it returns.
#
# NOT return values. The hydrate has a dozen early returns and each one would
# have to carry them, which is the rule the verdict itself already proved will be
# missed at the next return added. $null rather than 0 is the whole point: a zero
# age on a pool with no bucket configured would sit in the same series as a zero
# age on a pool whose snapshot is fresh, and no alert can tell those apart.
$script:CacheSnapAgeHours = $null
$script:CacheSnapBytes = $null
$script:CacheDirsHydrated = $null

# Defaults for a host booting from a template cut before these metadata keys
# existed. The live values come from Terraform, which validates them.
$script:CacheHydrateBudgetSeconds = 60
$script:CacheSnapshotMaxAgeHours = 168
$script:CacheSnapshotMaxBytes = 4GB

# The pointer object is tiny by construction -- one snapshot name -- and this is
# what stops a bucket that answers with something else from landing on the disk.
$script:CachePointerMaxBytes = 65536

# gzip expands by more than a thousandfold on the right input, so the bound on
# the COMPRESSED archive bounds nothing about what it writes. Same shape as
# host-startup.sh's cache_expand_bound: eight times the compressed size, with a
# floor so a tiny archive still gets a workable allowance.
$script:CacheExpandFloorBytes = 65536

# The loopback port the broker answers on when metadata does not name one. The
# same default as the Linux broker, because it is the same broker.
$script:DefaultBrokerPort = 8081
# The bottom of the Windows dynamic/ephemeral port range. A listener placed inside
# it is one an outbound connection can take first; see Get-BrokerPort.
$script:EphemeralPortFloor = 49152

# Where a slot's ADC is pointed when this pool has NO broker.
#
# Not a placeholder, and the single most load-bearing constant in this file.
# Leaving GCE_METADATA_* unset does NOT mean "no credentials": gcloud,
# google-auth and the Go and Java clients all fall through to the real
# 169.254.169.254 and authenticate as the HOST service account -- which is the
# exact silent downgrade the no-broker path claims never to make. Linux gets
# that property from fence_metadata, which runs unconditionally there and which
# section 3A deleted here; nothing replaced it until this constant did.
#
# A loopback port that is RESERVED, and therefore permanently unbindable,
# refuses the connection instantly. ADC then fails closed and says so, instead
# of succeeding as somebody else. Port 1 is chosen because no service anybody
# would run on a CI host wants it.
$script:ClosedMetadataPort = 1
$script:ClosedMetadataEndpoint = '127.0.0.1:1'

# The per-instance metadata key the controller writes the registration token to
# and deletes it from. Hard-coded on BOTH sides for the same reason
# controller-startup.sh hard-codes it: a configurable name is one more way for
# the delete to miss the key the write created.
$script:RegistrationTokenKey = 'ci-registration-token'

# The unconfigured agent baked into the golden image. COPIED per slot, never
# linked: config.cmd writes `.runner` and `.credentials` into the directory it
# runs in, and K agents must not share one identity.
$script:RunnerTemplate = 'C:\ci\bin\actions-runner'

# How long phase 5 waits for the controller to write the registration token.
# BOUNDED, and the bound is the whole point. `wait-for-change` on the metadata
# server would block until the key appears, which on a rebooted host past the
# expiry is forever -- and forever is the 2h55m outage: a host that never
# registers, never powers off, and counts against the pool's size the whole
# time. 300s is generous against a controller tick (POLL defaults to 20s) and
# still far inside the register grace that reclaims a host which gave up.
$script:RegistrationWaitSeconds = 300
$script:RegistrationPollSeconds = 5

# How long phase 5 waits, AFTER its agents are registered, for the controller to
# delete the registration-token key again. Section 3A requires the host to
# witness that deletion rather than assume it. Polled and not read once: the
# controller deletes on `partial`, which it learns on its own tick, so a single
# read taken the instant the last agent came up would fail on a healthy fleet.
#
# JITTERED, AND THE JITTER IS NOT DECORATION -- DO NOT TIDY IT INTO A CONSTANT.
# The thing being waited on is an action by ONE controller, so every host in a
# scale-out is waiting on the same actor. A controller that is restarting,
# backed up, or being rate-limited by the GitHub API makes every host booting in
# that window cross the same fixed deadline within seconds of every other one,
# and a hiccup becomes a fleet-wide refusal to serve at the moment capacity is
# being asked for. A slow controller is also, by a wide margin, the likelier
# event: a token that genuinely never gets deleted needs the controller to have
# minted one and then never seen the host register at all.
#
# So the bound is widened AND spread. Base 600s with up to 300s of jitter is
# still far inside any window in which an operator would notice the host, and
# the spread means a controller that recovers inside five minutes costs nothing.
#
# WHY 900s IS ACCEPTABLE AS A SECURITY BOUND AND NOT ONLY A CAPACITY ONE. The
# argument above is entirely about availability, so on its own it would justify
# any number at all. The security half is that this deadline does not bound the
# EXPOSURE, only the moment containment starts. The host cannot delete its own
# metadata; while it waits the token is readable by job code either way, and
# section 3A already accepts that window and bounds it elsewhere -- by the
# controller's delete on its own tick, and failing that by the registration
# token's one-hour expiry, which is the real ceiling and is not ours to move.
# 900s is a quarter of that ceiling. Shortening to 300s would buy at most ten
# minutes off a sixty-minute window that section 3A has already accepted, and
# would pay for it in the correlated case above -- the one where a slow
# controller, not a leaked token, is what actually happened.
#
# What this deadline DOES bound is how long a host keeps taking new jobs after
# the controller has visibly failed to clean up, and that is what
# Stop-RunnerService closes at the deadline.
$script:TokenRemovalWaitSeconds = 600
$script:TokenRemovalJitterSeconds = 300

function Get-JitteredTimeout {
    <#
      .SYNOPSIS
        Spread a fixed timeout across a window, from a roll in [0,1). Pure.
      .DESCRIPTION
        Split out from its caller so the spread itself is testable: the failure
        mode of jitter is a bound that silently became a constant, or one that
        became unbounded, and neither is visible from a call site that rolls its
        own dice. The roll is a parameter for the same reason.

        Not drawn from the crypto RNG this file uses for slot passwords. Jitter
        is a scheduling property and not a secret -- nothing is defended by an
        attacker being unable to predict when this host gives up -- and reaching
        for the entropy path here would suggest to the next reader that it is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $BaseSeconds,
        [Parameter(Mandatory = $true)][int] $JitterSeconds,
        [Parameter(Mandatory = $true)][double] $Roll
    )

    if ($JitterSeconds -le 0) { return $BaseSeconds }
    $bounded = [Math]::Max(0.0, [Math]::Min(1.0, $Roll))
    return ($BaseSeconds + [int] [Math]::Floor($bounded * $JitterSeconds))
}

# How long to wait for the agent service config.cmd auto-started to stop again,
# before its identity and environment are set. Bounded like everything else: a
# service that will not stop is a slot that would run every job as the shared
# machine account, and blocking forever hides that behind a hung boot.
$script:ServiceStopSeconds = 60

# Bounded, like every call this host makes. A host boot that HANGS is worse than
# one that fails: it never registers an agent, never powers off, and bills at
# warm-host size until the controller's register grace expires -- and while it
# waits it counts as a host the pool already has, so the pool does not add the
# one that would have taken the queued job. That is the 2h55m outage, restated.
$script:HttpTimeoutSeconds = 10

function Write-BootLog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Message)
    $line = '[{0}] {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message
    # NOT Write-Output, and NOT Write-Host. Write-Output puts the line on the
    # SUCCESS stream, so every function that logs and then returns a value
    # returns the log lines PLUS the value as an object[] -- which is a
    # boot-fatal fault, not a cosmetic one: `. $beaconPath` cannot dot-source an
    # array, `--token` receives a timestamped log line joined to the token, and
    # an object[] does not bind to an [IDictionary] parameter. Write-Host would
    # be correct behaviourally and fails PSAvoidUsingWriteHost, which
    # powershell-gate.sh runs at -Severity Error,Warning with no exclusions.
    # [Console]::Out.WriteLine writes straight to the process's stdout handle --
    # which is what the guest agent captures -- and can never be captured by
    # `$x = Some-Function`. Available on .NET Framework 4.8 / Windows
    # PowerShell 5.1, which is what runs this file.
    [Console]::Out.WriteLine($line)
    try {
        Add-Content -Path $script:LogPath -Value $line -ErrorAction Stop
    } catch {
        # The log is diagnostics. Losing it must not stop a boot.
        $null = $_
    }
}

function Deny-Boot {
    <#
      .SYNOPSIS
        Fail the boot loudly and stop.
      .DESCRIPTION
        There is no "continue without it" here. Every caller is a precondition
        whose absence makes the host either unsafe or useless, and a host that
        registers no agent is reclaimed by the controller's register-grace drain
        within minutes -- which is the cheap outcome. The expensive outcome is a
        host that half-worked.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Message)
    Write-BootLog "FATAL: $Message"
    throw $Message
}

# --- pure functions ----------------------------------------------------------
#
# Anything decidable without touching the machine lives here, so Pester can run
# it on ubuntu-latest (scripts/ci/windows-startup.Tests.ps1). A gate that READS
# code is not a test -- v5.1.4 passed every gate in ci.yml while every
# controller in the fleet died on its first tick.

function Test-ImageVersion {
    <#
      .SYNOPSIS
        Is this golden image at or above the floor the module requires?
      .DESCRIPTION
        The Linux script asserts `[ -d /opt/actions-runner ]` and refuses
        otherwise, because booting a bare image reintroduces the per-job install
        cost the pool exists to remove. A directory check is too weak here: a
        Windows image can carry a runner and still predate the service shim, the
        beacon source or the fence-proving probe, and each of those absences
        fails LATER and less legibly.

        So the Packer template writes an integer, and this compares it. Anything
        unreadable or non-numeric is a fail -- an image that cannot say what it
        is is not an image this pool knows how to run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Marker,
        [Parameter(Mandatory = $true)][int] $Floor
    )
    if ([string]::IsNullOrWhiteSpace($Marker)) { return $false }
    $trimmed = $Marker.Trim()
    if ($trimmed -notmatch '^[0-9]+$') { return $false }
    return ([int] $trimmed) -ge $Floor
}

function ConvertTo-MetricLabelValue {
    <#
      .SYNOPSIS
        A string safe to paste into the metric's JSON label fragment. Pure.
      .DESCRIPTION
        telemetry.sh's ts_label_value(), same allowlist, same cap, same fallback,
        because the two must produce the same label for the same verdict -- a
        Linux pool and a Windows pool grouped by `verdict` have to land in the
        same bucket or the fleet-wide chart silently splits in two.

        Allowlist rather than escape, for the reason telemetry.sh gives: escaping
        has to be right about quotes, backslashes, newlines and truncated UTF-8;
        an allowlist has to be right about one thing. A label slightly wrong beats
        a request the API rejects whole, which would drop every series in the
        flush -- including the verdict that says why.

        64 characters because a label value is also a cardinality decision.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Value)

    $safe = [regex]::Replace([string] $Value, '[^A-Za-z0-9._/ -]', '_')
    if ($safe.Length -gt 64) { $safe = $safe.Substring(0, 64) }
    if ([string]::IsNullOrEmpty($safe)) { return 'unknown' }
    return $safe
}

function ConvertTo-MetricRegion {
    <#
      .SYNOPSIS
        The region out of a metadata zone path. Pure. Empty when undecidable.
      .DESCRIPTION
        `instance/zone` answers `projects/<number>/zones/<region>-<letter>`, and
        the `generic_node` resource wants `<region>` in its `location` label --
        the same derivation host-startup.sh does with two parameter expansions.

        Empty rather than a guess on anything that does not have the shape: an
        undecidable location is a resource label the API rejects, and the caller
        skips the whole flush on an empty one. A zone spelled into `location`
        would publish, and would silently not join the Linux pools' series.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Zone)

    $leaf = ([string] $Zone).Split('/')[-1]
    # `<region>-<letter>`: at least two dash-separated parts, and the region
    # itself contains dashes (`us-central1`), so only the LAST one is dropped.
    if ($leaf -notmatch '^[a-z0-9]+(-[a-z0-9]+)+$') { return '' }
    return $leaf.Substring(0, $leaf.LastIndexOf('-'))
}

function ConvertTo-MetricPoint {
    <#
      .SYNOPSIS
        One timeSeries element, as a hashtable. Pure.
      .DESCRIPTION
        The same document telemetry.sh's _ts_point() writes: a GAUGE DOUBLE on a
        `generic_node` resource labelled with repo and pool. Uniform metric kind
        across the fleet on purpose -- a mixed kind makes a single alert policy
        impossible to express.

        A hashtable rather than a string, and ConvertTo-Json at the flush: the
        shell side builds JSON by concatenation because it has nothing else, and
        pays for it with ts_label_value. Here the serializer escapes, so the
        allowlist above is defence in depth rather than the only defence.

        Returned wrapped in a single-element array by the caller's `,` operator
        where needed; PowerShell unrolls a returned hashtable safely, so this
        returns it plainly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][double] $Value,
        [Parameter(Mandatory = $true)][string] $MetricPrefix,
        [Parameter(Mandatory = $true)][string] $Project,
        [Parameter(Mandatory = $true)][string] $Region,
        [Parameter(Mandatory = $true)][string] $Repo,
        [Parameter(Mandatory = $true)][string] $Pool,
        [hashtable] $ExtraLabels
    )

    $labels = @{ repo = $Repo; pool = $Pool }
    if ($ExtraLabels) {
        foreach ($k in $ExtraLabels.Keys) { $labels[$k] = ConvertTo-MetricLabelValue -Value $ExtraLabels[$k] }
    }

    return @{
        metric     = @{ type = "$MetricPrefix/$Name"; labels = $labels }
        resource   = @{
            type   = 'generic_node'
            labels = @{
                project_id = $Project
                location   = $Region
                namespace  = $Pool
                node_id    = $Repo
            }
        }
        metricKind = 'GAUGE'
        valueType  = 'DOUBLE'
        points     = @(
            @{
                interval = @{ endTime = ([datetime]::UtcNow).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                value    = @{ doubleValue = $Value }
            }
        )
    }
}

function Get-SlotUserName {
    <#
      .SYNOPSIS
        The local account name for slot <Index>.
      .DESCRIPTION
        `ci-s<i>`, matching the Linux `ci-s<idx>`. This is not cosmetic: the agent
        registered by this slot is named `<instance>-s<i>`, and
        `orphan_decision()` on the controller parses that name back to an
        instance. A rename here silently un-reaps every Windows registration --
        the agent stays in GitHub's list, the host it named is long gone, and
        nothing in the controller notices because nothing can.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Index)
    return "ci-s$Index"
}

function Get-SlotWorkspacePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $Root = $script:SlotRoot
    )
    return (Join-Path $Root ([string] $Index))
}

function Get-SlotTempPath {
    <#
      .SYNOPSIS
        The slot's private TEMP.
      .DESCRIPTION
        The Linux rule this replaces: a workflow step naming a fixed path under
        /tmp -- and CI scripts name fixed paths there constantly -- creates it
        under whichever slot ran first, and every later slot gets Permission
        denied on a file it believes is its own. Linux fixes that with
        PrivateTmp=yes on the daemon. Windows has no mount namespace to give a
        service, so the mechanism is a per-slot directory carrying the slot's ACL,
        pointed at by TMP and TEMP in the runner SERVICE's environment (phase 5)
        rather than machine-wide, which would hand every slot the same one.

        Weaker than the Linux fix, and the difference is stated rather than
        discovered: this redirects the CONVENTIONAL temp path, and nothing stops a
        step writing to a literal C:\temp\build. What the ACLs do is turn that
        collision from a silent cross-slot read into an Access is denied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $Root = $script:SlotRoot
    )
    return (Join-Path (Get-SlotWorkspacePath -Index $Index -Root $Root) 'temp')
}

# The four character classes Windows complexity policy wants, minus every
# homoglyph (I, l, 1, O, 0) and every shell, quoting or XML metacharacter. This
# value reaches the service control manager, and a quoting bug here would be a
# quoting bug in the one place it is a credential; a password that cannot be read
# back off a console during an incident wastes the incident.
$script:SlotPasswordClasses = @(
    'ABCDEFGHJKLMNPQRSTUVWXYZ',
    'abcdefghijkmnpqrstuvwxyz',
    '23456789',
    '_-.~'
)

function Get-SlotPasswordCharacter {
    <#
      .SYNOPSIS
        The characters of one slot password, as a char array. Pure and testable.
      .DESCRIPTION
        Windows requires a password here: a service logon takes a credential and
        there is no `sudo -u` on this platform. That is a real difference from
        Linux, where no such secret exists, and it is contained by making the
        credential useless for anything else -- the account is granted
        SeServiceLogonRight and DENIED interactive, network and remote-interactive
        logon, is not in Administrators, and is not in Remote Desktop Users.

        One character from each class is placed first and the whole thing is then
        shuffled, so complexity is satisfied by construction rather than by luck.
        A password rejected by policy is a slot that never registers, and it would
        be discovered on the fleet rather than here.

        Returns chars, not a string, so the caller can build a SecureString
        without a plaintext String ever existing on the managed heap. The array is
        the caller's to clear.

        The verb is Get and not New because PSUseShouldProcessForStateChangingFunctions
        demands -WhatIf plumbing from a New-* function, and a boot script that
        half-honours -WhatIf is a worse thing than an imperfect verb.
    #>
    [CmdletBinding()]
    param([int] $Length = 40)

    $classes = $script:SlotPasswordClasses
    if ($Length -lt $classes.Count) {
        throw "slot password length $Length cannot satisfy $($classes.Count) character classes"
    }
    $all = -join $classes

    # Four bytes of entropy per character, drawn once. The modulo bias over a
    # 32-bit draw into an at-most-64-character alphabet is far below anything that
    # matters for a 40-character secret that never leaves the machine.
    #
    # Instance + GetBytes(byte[]), never the static one-liner that takes a
    # Span<byte>, and never the class's own bounded-integer helper. Both of those
    # arrived with .NET Core and have no .NET Framework overload at all. This
    # script is handed to the guest agent as `windows-startup-script-ps1`, which
    # the agent runs with the in-box powershell.exe -- Windows PowerShell 5.1 on
    # .NET Framework 4.8 -- so either would throw MethodNotFound right here and
    # every host in the pool would fail phase 1 and deny its own boot. The Pester
    # suite runs this function under pwsh 7, where both exist, so the runtime that
    # actually matters is the one no test covers. Create(), GetBytes(byte[]) and
    # Dispose() are present in every .NET Framework the fleet can boot on and in
    # .NET Core, which makes this the one form that runs in both.
    $bytes = [byte[]]::new($Length * 4)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }

    $chars = [char[]]::new($Length)
    for ($i = 0; $i -lt $classes.Count; $i++) {
        $set = $classes[$i]
        $chars[$i] = $set[[int]([BitConverter]::ToUInt32($bytes, $i * 4) % [uint32] $set.Length)]
    }
    for ($i = $classes.Count; $i -lt $Length; $i++) {
        $chars[$i] = $all[[int]([BitConverter]::ToUInt32($bytes, $i * 4) % [uint32] $all.Length)]
    }
    for ($i = $Length - 1; $i -gt 0; $i--) {
        $j = [int]([BitConverter]::ToUInt32($bytes, $i * 4) % [uint32]($i + 1))
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    [array]::Clear($bytes, 0, $bytes.Length)
    return $chars
}

function Get-SlotPassword {
    <#
      .SYNOPSIS
        A slot password as a SecureString, with no plaintext String in between.
      .DESCRIPTION
        Deliberately never materialises a [string]. `ConvertTo-SecureString
        -AsPlainText -Force` is the usual shortcut and it is the wrong one twice
        over: it puts an immutable, un-erasable copy of the credential on the
        managed heap for the lifetime of the process, and PSScriptAnalyzer flags
        it -- which would mean either a failing gate or a suppression, and a
        suppressed warning about a credential is how the next one gets suppressed
        too.

        Everything downstream takes a SecureString or a PSCredential: New-LocalUser,
        Set-LocalUser, and the service registration in phase 5. So the plaintext
        form is never needed at all, and this script never writes it to disk, never
        logs it and never puts it in metadata. After registration LSA holds it as a
        service secret, readable only by SYSTEM.
    #>
    [CmdletBinding()]
    param([int] $Length = 40)

    $chars = Get-SlotPasswordCharacter -Length $Length
    $secure = New-Object System.Security.SecureString
    foreach ($c in $chars) { $secure.AppendChar($c) }
    [array]::Clear($chars, 0, $chars.Length)
    $secure.MakeReadOnly()
    return $secure
}

function Get-BeaconServiceConfig {
    <#
      .SYNOPSIS
        The shim's service definition for the beacon, as XML text.
      .DESCRIPTION
        Written as a pure string function so the parts that decide fleet
        behaviour are asserted by a test rather than by a host that has already
        booted. Three of them matter and none is cosmetic:

        `<onfailure action="restart">` -- the publisher stopping is the failure
        that strands a host. `beacon_decision()` reads a stale beacon as keep,
        forever, so a beacon that dies once and stays dead is a machine that
        bills until somebody notices.

        `<startmode>Automatic</startmode>` -- the host must come back beaconing
        after any restart, including one it did not choose.

        `-NonInteractive -NoProfile` -- a profile on the image, or a prompt from
        anything the script calls, would hang the service at start, which the SCM
        reports as a start failure and which looks nothing like its cause.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [string] $ServiceName = $script:BeaconServiceName,
        [int] $IntervalSeconds = 30
    )
    # Escaped, exactly as Get-BrokerServiceConfig escapes its inputs. Both of
    # these are module constants today, so there is no live injection here; the
    # point is that the two builders must not differ, because the next caller
    # will reuse whichever one it finds first and will not read this comment.
    $esc = { param($v) [System.Security.SecurityElement]::Escape([string] $v) }
    $svc = & $esc $ServiceName
    $shimArgs = & $esc ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" " +
        "-IntervalSeconds $IntervalSeconds")
    return @"
<service>
  <id>$svc</id>
  <name>$svc</name>
  <description>Publishes this CI host's liveness to GCE guest attributes.</description>
  <executable>powershell.exe</executable>
  <arguments>$shimArgs</arguments>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <resetfailure>1 hour</resetfailure>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>2</keepFiles>
  </log>
</service>
"@
}

function Test-JobServiceAccountName {
    <#
      .SYNOPSIS
        Is this a service-account address, and nothing else?
      .DESCRIPTION
        Instance metadata is a trust boundary: section 3A accepts that job code on a
        Windows host can read it, and this module cannot assume nothing can write
        it either. The value goes into the broker's service definition, which is
        XML, and into the service's environment block, so a value carrying a
        quote, an angle bracket or a newline is a way to add an element or a
        variable to a service that runs as LocalSystem.

        Escaping alone would be enough for the XML and is done anyway. This is
        the other half: the only thing that may reach either place is something
        shaped like the address the broker is going to impersonate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return ($Name.Trim() -match '^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$')
}

function Get-BrokerPort {
    <#
      .SYNOPSIS
        The broker's loopback port, or the default when metadata gives nothing.
      .DESCRIPTION
        Same trust-boundary reasoning as the account name, with a narrower range:
        anything that is not a whole number in 1..65535 is a value the socket bind
        would refuse LATER, at which point the broker is a service that installed
        and never answered. The ephemeral range 49152-65535 is excluded for the
        same outcome by a different route: the bind succeeds until an outbound
        socket gets there first. Falling back is right here and would be wrong for
        the account: a default port serves the same broker, a default identity
        would be somebody else's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Value,
        [int] $Default = $script:DefaultBrokerPort
    )
    if ($Value -notmatch '^[0-9]+$') { return $Default }
    # TryParse, not a cast. `[int64] '99999999999999999999'` THROWS, and under the
    # entry point's $ErrorActionPreference = 'Stop' that throw is a dead host with
    # a cast error in its log instead of a working one on the default port. An
    # all-digits string is not the same thing as a number that fits, and the gap
    # between the two is exactly what a metadata value can be set to.
    [int64] $port = 0
    if (-not [int64]::TryParse($Value, [ref] $port)) { return $Default }
    if ($port -lt 1 -or $port -gt 65535) { return $Default }
    # ...and not the EPHEMERAL range either. Windows draws outbound source ports
    # from 49152-65535, so a broker told to listen there is racing every socket the
    # host opens -- and it loses the race silently, as a service that installed and
    # then did not answer on the port the log says it is on. Availability only, but
    # this picker is the only place that can tell the difference between a port
    # somebody chose and one the stack hands out.
    if ($port -ge $script:EphemeralPortFloor) { return $Default }
    return [int] $port
}

function Get-BrokerServiceConfig {
    <#
      .SYNOPSIS
        The shim's service definition for the job credential broker, as XML text.
      .DESCRIPTION
        Pure, for the same reason Get-BeaconServiceConfig is: the parts that
        decide whether job code gets the RIGHT identity are asserted by a test
        rather than by a host that has already registered agents.

        `CI_BROKER_HOST` is 127.0.0.1, and that is the one line here that looks
        like a regression against Linux. On Linux the broker binds 0.0.0.0 and the
        script then REJECTs the port on the primary interface, purely because each
        slot has its own network namespace and therefore its own loopback, so a
        broker on the host's 127.0.0.1 would be unreachable from every slot.
        Windows has no per-slot namespace (section 4 of the ADR), every slot shares one
        loopback, and binding the VM's address instead would add an exposure in
        exchange for nothing.

        The service runs as LocalSystem -- the shim's default, and deliberate. The
        broker is the one process on this host whose job is to hold a host-level
        credential briefly and hand back a weaker one; running it as a slot would
        put that exchange inside the boundary it exists to cross.

        Every value that comes from metadata is XML-escaped AND validated by the
        caller. Escaping alone stops a malformed document; validation stops a
        well-formed one that says something else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [Parameter(Mandatory = $true)][string] $JobServiceAccount,
        [Parameter(Mandatory = $true)][int] $Port,
        [string] $ServiceName = $script:BrokerServiceName,
        [string] $PythonPath = $script:PythonExe
    )
    $esc = { param($v) [System.Security.SecurityElement]::Escape([string] $v) }
    $exe = & $esc $PythonPath
    $arg = & $esc "`"$ScriptPath`""
    $sa = & $esc $JobServiceAccount
    $svc = & $esc $ServiceName
    return @"
<service>
  <id>$svc</id>
  <name>$svc</name>
  <description>Vends job-scoped Google credentials to CI job code on this host.</description>
  <executable>$exe</executable>
  <arguments>$arg</arguments>
  <env name="CI_JOB_SERVICE_ACCOUNT" value="$sa"/>
  <env name="CI_BROKER_HOST" value="127.0.0.1"/>
  <env name="CI_BROKER_PORT" value="$Port"/>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <resetfailure>1 hour</resetfailure>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>2</keepFiles>
  </log>
</service>
"@
}

function Test-MetadataAbsence {
    <#
      .SYNOPSIS
        Does this metadata failure mean "not set", as opposed to "not readable"?
      .DESCRIPTION
        Pure, so the distinction the whole fail-closed rule rests on is asserted
        by a test rather than by a host that has already registered agents. A
        $null status is the case that matters most: it is what a DNS failure, a
        refused connection or a read timeout looks like, and it is precisely the
        case the old catch-everything handler reported as an empty attribute.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()] $StatusCode)
    if ($null -eq $StatusCode) { return $false }
    return ([int] $StatusCode -eq 404)
}

function Get-PortReservationArgument {
    <#
      .SYNOPSIS
        The netsh argument vector that makes one TCP port unbindable, as an array.
      .DESCRIPTION
        Pure, because the arguments are the whole content: a reservation that
        names the wrong protocol or a range of the wrong length is a reservation
        that silently protects nothing, and there is no way to notice that on a
        host afterwards -- the port is simply free again the day somebody wants
        it.

        Used for the closed-metadata port only. The BROKER's port is deliberately
        not reserved: an excluded range blocks explicit binds too, so reserving
        it would lock out the one process that is supposed to have it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Port)
    return @(
        'int', 'ipv4', 'add', 'excludedportrange',
        'protocol=tcp', "startport=$Port", 'numberofports=1'
    )
}

function Test-BrokerListenerSid {
    <#
      .SYNOPSIS
        Is the process listening on the broker's port LocalSystem?
      .DESCRIPTION
        The readiness probe's other half, and pure for the same reason. Every
        slot on a Windows host shares one loopback (section 4) and nothing
        reserves the broker's port, so between a broker crash and the shim's
        10-second restart the port is free -- and a process a job left behind can
        take it and answer with a metadata-shaped document of its own choosing.
        The token probe cannot tell the difference; the owner can. A slot account
        cannot become S-1-5-18, so this is the property, not a heuristic.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Sid)
    if ([string]::IsNullOrWhiteSpace($Sid)) { return $false }
    return ($Sid.Trim() -eq 'S-1-5-18')
}

function Get-SlotStatePath {
    <#
      .SYNOPSIS
        One slot's state directory. SYSTEM writes it, the slot reads it.
      .DESCRIPTION
        The marker, the verdict and the recorded runner service name live here,
        and none of the three may be writable by the slot they describe: a slot
        that could write its own `clean` marker could vouch for itself, which is
        the whole of what the gate refuses to let it do.

        -StateRoot is injectable for the reason Get-SlotServiceEnvironment's
        -SlotRoot is: the suite runs on ubuntu-latest, where a path builder that
        insists on `C:\` is a pure function nothing can call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $StateRoot = $script:StateRoot
    )
    return (Join-Path $StateRoot ([string] $Index))
}

function Get-SlotRequestPath {
    <#
      .SYNOPSIS
        The one directory a slot may write in order to ask for a reset.
      .DESCRIPTION
        This directory IS the privilege split. There is no `sudo` on Windows and
        no SUDO_UID, so nothing about a request can be authenticated from its
        contents; what can be authenticated is WHERE it appeared, because phase 4
        grants write on `<state>\<i>\request` to `ci-s<i>` and to no other slot.
        A job that writes a file naming slot 0 has written a file in its own
        directory saying something the service never reads.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $StateRoot = $script:StateRoot
    )
    return (Join-Path (Get-SlotStatePath -Index $Index -StateRoot $StateRoot) 'request')
}

function Get-SlotMarkerPath {
    <#
      .SYNOPSIS
        The `clean` marker: written by the reset, deleted by the gate.
      .DESCRIPTION
        Deleted at the START of a job rather than written at the end of one, and
        that asymmetry is the fail-closed half. A slot whose predecessor was
        killed mid-reset has no marker, so the next job on it is failed rather
        than run -- the same property host-startup.sh's marker carries, spelled in
        NTFS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $StateRoot = $script:StateRoot
    )
    return (Join-Path (Get-SlotStatePath -Index $Index -StateRoot $StateRoot) 'clean')
}

function Get-SlotVerdictPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $StateRoot = $script:StateRoot
    )
    return (Join-Path (Get-SlotStatePath -Index $Index -StateRoot $StateRoot) 'verdict')
}

function Get-SlotRunnerServicePath {
    <#
      .SYNOPSIS
        Where phase 5 records the runner service name the reset is allowed to stop.
      .DESCRIPTION
        NOT the agent's own `.service` marker, which is the file
        Get-RunnerServiceName reads. That file lives inside the slot's runner
        directory, which the slot account can write, and the name inside it
        reaches Stop-Service running as SYSTEM. Phase 5 has already validated it
        twice -- shape, and ownership by this slot's agent name -- so what is
        recorded here is the validated result, in a directory no slot can write.

        Missing means no reset: the service has nothing it will vouch for
        stopping, so it writes no marker and the next job is failed. Closed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $StateRoot = $script:StateRoot
    )
    return (Join-Path (Get-SlotStatePath -Index $Index -StateRoot $StateRoot) 'service')
}

function Get-SlotProfileTemplatePath {
    <#
      .SYNOPSIS
        The pristine copy of one slot's profile, captured once at boot.
      .DESCRIPTION
        SYSTEM and Administrators only, with no slot ACE at all -- unlike the hook
        directory, which every slot must be able to execute out of. A slot able to
        write its own template would be handing every later job on that slot
        whatever it left there, which is the persistence the wholesale replacement
        exists to end.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $Root = $script:ProfileTemplateRoot
    )
    return (Join-Path $Root (Get-SlotUserName -Index $Index))
}

function Get-RequestSlotIndex {
    <#
      .SYNOPSIS
        Which slot a request file names, decided by its PATH. Pure. '' when none.
      .DESCRIPTION
        The one function that decides whose profile gets replaced, so it is
        separated out and tested rather than written inline in a service payload
        nothing off Windows can execute.

        The rule is the ADR's: the slot is the directory, never the content. A
        request is `<state>\<index>\request\<name>`, and this returns the index
        only when all three of the parent, the grandparent and the index itself
        are what they must be. Anything else returns '' and the caller ignores the
        file -- including, deliberately, a path with `..` in it, which is refused
        by the index pattern rather than resolved.

        Returns a STRING, because '' is the no-answer and 0 is a real slot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    # Split on both separators. The service builds these paths itself, but this
    # function's whole job is to be the thing that does not assume that.
    $parts = @($Path -split '[\\/]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 3) { return '' }
    if ($parts[-2] -cne 'request') { return '' }
    $index = $parts[-3]
    # Leading zeros excluded: `01` and `1` would be two names for one slot, and
    # two names for one slot is how a marker gets written beside the one being
    # read rather than over it.
    if ($index -notmatch '^(0|[1-9][0-9]*)$') { return '' }
    return $index
}

function Test-ResetRequestName {
    <#
      .SYNOPSIS
        Is this a request name the service acts on? Pure.
      .DESCRIPTION
        Exactly two names, matched case-sensitively and in full. The service
        deletes the file before acting on it, so an unrecognised name that were
        accepted here would be a slot choosing which of the two very different
        code paths -- a gate, or a service stop and a profile replacement -- runs
        against it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Name)
    if ($null -eq $Name) { return $false }
    return ($Name -cin @('started', 'completed'))
}

function Test-ResetVerdictClean {
    <#
      .SYNOPSIS
        Does this verdict text let a job run? Pure, and false for everything odd.
      .DESCRIPTION
        `clean`, case-sensitively, after trimming, and nothing else. Written as a
        function rather than an inline comparison because every interesting way to
        get this wrong is a way to say yes: a `-like 'clean*'` accepts
        `clean-failed`, a case-insensitive match accepts a file somebody edited by
        hand, and a null-tolerant one accepts a verdict that was never written.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text.Trim() -ceq 'clean')
}

function Test-SlotProfileDirectory {
    <#
      .SYNOPSIS
        May this directory be replaced as slot <Index>'s profile? Pure.
      .DESCRIPTION
        Carried over verbatim from the credential hook this replaces, because it
        was the security half of it and it is the security half of this -- with
        one clause added. The old hook checked the leaf was SOME `ci-s<n>`; this
        checks it is THIS slot's, because the caller is now SYSTEM resetting a slot
        it was told about, not a slot cleaning its own profile. A ProfileList entry
        that resolved to a sibling's directory would otherwise have SYSTEM wipe the
        profile of a slot that is mid-job.

        The path being tested is read from the account database -- the SID's
        ProfileImagePath -- and never from %USERPROFILE%, for the reason the Linux
        script reads `getent passwd`: the directory being emptied is the host's
        decision, not a variable's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Path,
        [Parameter(Mandatory = $true)][int] $Index
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $parts = @($Path -split '[\\/]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 2) { return $false }
    return ($parts[-1] -ceq (Get-SlotUserName -Index $Index))
}

function Test-SlotProcessKillable {
    <#
      .SYNOPSIS
        May the quiesce terminate this process? Pure, and false unless certain.
      .DESCRIPTION
        The Windows spelling of host-startup.sh's sweep, and it exists for the
        identical reason (#237): a background process the job left running holds a
        writable profile and can put a dotfile back AFTER the replacement, at which
        point the marker certifies a slot that is not clean.

        What Windows does not have is the cgroup Linux uses to spare the agent and
        its rootless daemon, so the sparing is done by identity and by ancestry:

          * OWNERSHIP is the whole filter, and it is an exact SID match. A name
            match would be wrong twice -- `ci-s1` is a prefix of nothing here but
            would be of `ci-s10`, and a display name is resolved through a
            locale-dependent account database this module has no say in.
          * The RESET'S OWN process tree is spared. It runs as SYSTEM, so it does
            not match the SID filter at all today; the parameter exists because the
            first thing anybody adding "and also kill orphans" will reach for is a
            wider filter, and this is where that gets stopped.
          * PIDs 0 and 4 are refused outright. Neither can be owned by a slot, and
            a lookup that returned one of them means the enumeration is answering
            about something other than what was asked.

        An UNKNOWN owner is false, not true. GetOwnerSid fails on a process that
        exited between the enumeration and the query, and it fails the same way on
        one running as an identity this code could not read -- so the safe answer
        is to leave it and let the marker be withheld if it is still there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $OwnerSid,
        [Parameter(Mandatory = $true)][string] $SlotSid,
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [int[]] $SpareProcessId = @()
    )
    if ([string]::IsNullOrWhiteSpace($OwnerSid)) { return $false }
    if ($ProcessId -le 4) { return $false }
    if (@($SpareProcessId) -contains $ProcessId) { return $false }
    return ($OwnerSid.Trim() -ceq $SlotSid)
}

function Get-SlotResetServiceConfig {
    <#
      .SYNOPSIS
        The shim's service definition for the reset service, as XML text.
      .DESCRIPTION
        Pure, like the beacon's and the broker's, and the three values that decide
        whether the fleet is safe are the same three:

        `<onfailure action="restart">` -- a reset service that has died is a host
        on which every COMPLETED request piles up unserved and every later job
        fails at its gate. That is fail-closed, and it is also every slot on the
        host out of service until somebody looks, so it restarts.

        `<startmode>Automatic</startmode>` -- the host must come back able to reset
        after any restart, including one it did not choose.

        LocalSystem, the shim's default and the entire point: the thing being
        stopped is a service, the thing being replaced is another account's
        profile, and neither is reachable from the slot asking for it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [string] $ServiceName = $script:SlotResetServiceName,
        [int] $PollSeconds = $script:SlotResetPollSeconds
    )
    $esc = { param($v) [System.Security.SecurityElement]::Escape([string] $v) }
    $svc = & $esc $ServiceName
    $shimArgs = & $esc ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" " +
        "-PollSeconds $PollSeconds")
    return @"
<service>
  <id>$svc</id>
  <name>$svc</name>
  <description>Resets a CI slot's profile between jobs, and vouches for the result.</description>
  <executable>powershell.exe</executable>
  <arguments>$shimArgs</arguments>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <resetfailure>1 hour</resetfailure>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>2</keepFiles>
  </log>
</service>
"@
}

function Get-SlotResetScript {
    <#
      .SYNOPSIS
        The body of the SYSTEM-side reset service. Text, with paths substituted.
      .DESCRIPTION
        Emitted as text for the reason the boot probe's payload is: this script
        arrives as instance metadata and is never a file on the disk, so a payload
        that wanted to dot-source it would have nothing to source. What can be
        tested off Windows is therefore the DECISIONS, which live in the pure
        functions above and are called by name from in here, plus the STRUCTURE of
        this text, which the shell gate asserts the way host-startup.selftest.sh
        asserts the Linux here-doc.

        A single-quoted here-string with @TOKEN@ placeholders, not an interpolated
        one: the payload must read on disk exactly as it reads here, and the five
        substitutions are made explicitly at the end so a reader can see the entire
        set of things this script gets to inject.

        THE ORDER OF THE LAST TWO STEPS DIFFERS FROM THE ADR, DELIBERATELY

        The ADR (phase 4, decision 2) says restart the service, then write the
        marker. That has a window: the agent is back and dispatchable while the
        marker it will be gated on does not exist yet, so a job that arrives inside
        it is failed for a reset that in fact succeeded. The marker is therefore
        written FIRST and the service started after it. Nothing weakens: the marker
        still says only "the reset finished", and a crash between the two leaves a
        marker with a stopped agent, which is a slot that takes no jobs rather than
        one that takes them unproved.
    #>
    [CmdletBinding()]
    param(
        [string] $StateRoot = $script:StateRoot,
        [string] $TemplateRoot = $script:ProfileTemplateRoot,
        [string] $LogPath = $script:LogPath,
        [int] $QuiesceWaitSeconds = 30,
        [int] $CopySeconds = $script:SlotResetCopySeconds
    )
    $body = @'
# Installed by windows-host-startup.ps1 (phase 4) and supervised by the service
# shim as LocalSystem. Serves reset requests dropped by the job hooks; see
# Get-SlotResetScript, and docs/adr-windows-pool.md phase 4, for why it is a
# service and not a scheduled task.
[CmdletBinding()]
param([int] $PollSeconds = 2)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateRoot = '@STATE_ROOT@'
$TemplateRoot = '@TEMPLATE_ROOT@'
$LogPath = '@LOG_PATH@'
$QuiesceWaitSeconds = @QUIESCE_SECONDS@

function Write-ResetLog {
    param([Parameter(Mandatory = $true)][string] $Message)
    $line = ('{0} slot-reset: {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Message)
    try { Add-Content -LiteralPath $LogPath -Value $line -ErrorAction Stop } catch { $null = $_ }
}

# Written through a temporary file and moved into place. A reader polling this
# path is another process, and a partial read of `clean` is `cle` -- which
# Test-ResetVerdictClean correctly rejects, failing a job whose slot was fine.
function Write-Atomic {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Text
    )
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# The slot is the DIRECTORY the request appeared in, never anything inside the
# file. Nothing below reads a request's contents at all.
function Get-RequestSlotIndex {
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $parts = @($Path -split '[\\/]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 3) { return '' }
    if ($parts[-2] -cne 'request') { return '' }
    $index = $parts[-3]
    if ($index -notmatch '^(0|[1-9][0-9]*)$') { return '' }
    return $index
}

function Test-ResetRequestName {
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Name)
    if ($null -eq $Name) { return $false }
    return ($Name -cin @('started', 'completed'))
}

function Test-SlotProfileDirectory {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Path,
        [Parameter(Mandatory = $true)][int] $Index
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $parts = @($Path -split '[\\/]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 2) { return $false }
    return ($parts[-1] -ceq "ci-s$Index")
}

function Test-SlotProcessKillable {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $OwnerSid,
        [Parameter(Mandatory = $true)][string] $SlotSid,
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [int[]] $SpareProcessId = @()
    )
    if ([string]::IsNullOrWhiteSpace($OwnerSid)) { return $false }
    if ($ProcessId -le 4) { return $false }
    if (@($SpareProcessId) -contains $ProcessId) { return $false }
    return ($OwnerSid.Trim() -ceq $SlotSid)
}

function Get-SlotSid {
    param([Parameter(Mandatory = $true)][int] $Index)
    $account = New-Object System.Security.Principal.NTAccount("ci-s$Index")
    return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

# The account database, for the reason the Linux script reads getent passwd: the
# directory about to be emptied is the host's decision and not a variable's.
function Get-SlotProfileDirectory {
    param([Parameter(Mandatory = $true)][string] $Sid)
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    $raw = (Get-ItemProperty -LiteralPath $key -Name 'ProfileImagePath').ProfileImagePath
    return [System.Environment]::ExpandEnvironmentVariables([string] $raw)
}

# Terminate every process whose token names this slot, then say whether any
# survived. The caller withholds the marker when one does: a writer that will not
# die is exactly the case where "the files were removed" stops being a claim
# about the slot.
function Invoke-SlotQuiesce {
    param(
        [Parameter(Mandatory = $true)][string] $Sid,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds
    )
    $spare = @($PID)
    foreach ($pass in @('stop', 'kill')) {
        $victims = @()
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)) {
            $owner = ''
            try {
                $owner = [string] (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid `
                        -ErrorAction Stop).Sid
            } catch { $null = $_ }
            if (Test-SlotProcessKillable -OwnerSid $owner -SlotSid $Sid `
                    -ProcessId ([int] $p.ProcessId) -SpareProcessId $spare) {
                $victims += [int] $p.ProcessId
            }
        }
        if ($victims.Count -eq 0) { return $true }
        Write-ResetLog "$pass pass: $($victims.Count) process(es) still owned by $Sid"
        foreach ($victim in $victims) {
            try { Stop-Process -Id $victim -Force -ErrorAction Stop } catch { $null = $_ }
        }
        Start-Sleep -Seconds ([Math]::Max(1, [int] ($TimeoutSeconds / 6)))
    }
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)) {
        $owner = ''
        try {
            $owner = [string] (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid `
                    -ErrorAction Stop).Sid
        } catch { $null = $_ }
        if (Test-SlotProcessKillable -OwnerSid $owner -SlotSid $Sid `
                -ProcessId ([int] $p.ProcessId) -SpareProcessId $spare) {
            return $false
        }
    }
    return $true
}

# NTUSER.DAT is held open for as long as anything runs as the account, and there
# is no supported way to replace a loaded hive underneath a live session. HKU
# losing the SID is how the host says the session is gone.
function Wait-HiveUnloaded {
    param(
        [Parameter(Mandatory = $true)][string] $Sid,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$Sid")) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds 1
    }
}

# /MIR, because the claim is "nothing of the last job survives" and a copy that
# only adds is a copy that keeps whatever was added. /COPY:DAT and not :DATS: the
# destination is the live profile and its ACL is the host's, not the template's.
# /XJ so a junction a job planted is replaced rather than followed out of the
# profile and mirrored over whatever it pointed at.
#
# BOUNDED, and Start-Process rather than the call operator is the whole reason
# why: the operator blocks until the child exits and offers nothing to ask once
# it is running, so one wedged mirror -- a filter driver, an AV scanner, a handle
# nobody releases -- is a poll loop that never serves another slot. Killed
# reports -1, which the caller reads as a failure and withholds the marker for.
function Copy-ProfileTree {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [int] $TimeoutSeconds = @COPY_SECONDS@
    )
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    $proc = $null
    $code = -1
    try {
        $proc = Start-Process -FilePath 'robocopy.exe' -PassThru -NoNewWindow `
            -RedirectStandardOutput $out -RedirectStandardError $err `
            -ArgumentList @($Source, $Destination, '/MIR', '/XJ', '/COPY:DAT', '/R:1', '/W:1',
            '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill(); [void] $proc.WaitForExit(5000) } catch { $null = $_ }
            Write-ResetLog "robocopy did not finish within $TimeoutSeconds s and was killed"
            return $false
        }
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } catch {
        Write-ResetLog "robocopy could not be started -- $($_.Exception.Message)"
        return $false
    } finally {
        if ($proc) { $proc.Dispose() }
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
    }
    # Robocopy's exit code is a bit field: 0-7 is success and 8 or more is not.
    # NEGATIVE is a failure too -- a killed robocopy exits with the NTSTATUS as a
    # negative integer, and a bare `-lt 8` reads every one of those as success.
    return ($code -ge 0 -and $code -lt 8)
}

function Invoke-SlotReset {
    param([Parameter(Mandatory = $true)][int] $Index)

    $state = Join-Path $StateRoot ([string] $Index)
    $marker = Join-Path $state 'clean'
    $template = Join-Path $TemplateRoot "ci-s$Index"
    $servicePath = Join-Path $state 'service'

    # Gone before anything else happens, so a reset that dies halfway through
    # leaves a slot that fails its next gate rather than one still vouched for.
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }

    if (-not (Test-Path -LiteralPath $template)) {
        Write-ResetLog "slot $Index has no profile template at $template -- no reset, no marker"
        return
    }
    if (-not (Test-Path -LiteralPath $servicePath)) {
        Write-ResetLog "slot $Index has no recorded runner service -- no reset, no marker"
        return
    }
    # Phase 5 wrote this after Get-RunnerServiceName validated it twice, into a
    # directory no slot can write. Re-checked here anyway, because the value
    # reaches Stop-Service running as SYSTEM and one validation in another phase
    # is not a property of this one.
    $serviceName = ([string] (Get-Content -Raw -LiteralPath $servicePath)).Trim()
    if ($serviceName -notmatch '^actions\.runner\.[A-Za-z0-9._-]+$') {
        Write-ResetLog "slot $Index recorded an unusable runner service name -- no reset, no marker"
        return
    }

    $sid = Get-SlotSid -Index $Index
    $profileDir = Get-SlotProfileDirectory -Sid $sid
    if (-not (Test-SlotProfileDirectory -Path $profileDir -Index $Index)) {
        Write-ResetLog "slot $Index resolved to '$profileDir', which is not its profile -- refusing"
        return
    }

    try {
        Stop-Service -Name $serviceName -Force -ErrorAction Stop
    } catch {
        Write-ResetLog "slot $Index -- could not stop $serviceName ($($_.Exception.Message))"
        return
    }

    if (-not (Invoke-SlotQuiesce -Sid $sid -TimeoutSeconds $QuiesceWaitSeconds)) {
        Write-ResetLog "slot $Index still has a process running as $sid -- no marker"
        return
    }
    if (-not (Wait-HiveUnloaded -Sid $sid -TimeoutSeconds $QuiesceWaitSeconds)) {
        Write-ResetLog "slot $Index -- the profile hive did not unload, so nothing was replaced"
        return
    }
    if (-not (Copy-ProfileTree -Source $template -Destination $profileDir)) {
        Write-ResetLog "slot $Index -- robocopy could not restore $profileDir from $template"
        return
    }

    # BEFORE the service starts, not after. See Get-SlotResetScript: an agent that
    # is dispatchable while its marker does not yet exist fails a job over a reset
    # that worked.
    Write-Atomic -Path $marker -Text 'clean'
    try {
        Start-Service -Name $serviceName -ErrorAction Stop
    } catch {
        Write-ResetLog "slot $Index -- reset done but $serviceName would not start ($($_.Exception.Message))"
        return
    }
    Write-ResetLog "slot $Index reset from $template"
}

# The gate. It does not reset anything -- the job asking is running under the
# service a reset would stop -- it reads the marker the last reset left, consumes
# it, and says what it found.
function Invoke-SlotGate {
    param([Parameter(Mandatory = $true)][int] $Index)
    $state = Join-Path $StateRoot ([string] $Index)
    $marker = Join-Path $state 'clean'
    $verdict = Join-Path $state 'verdict'
    $answer = 'dirty'
    if (Test-Path -LiteralPath $marker) {
        Remove-Item -LiteralPath $marker -Force
        $answer = 'clean'
    }
    Write-Atomic -Path $verdict -Text $answer
    Write-ResetLog "slot $Index gate: $answer"
}

Write-ResetLog "started, polling $StateRoot every $PollSeconds s"
while ($true) {
    # -Depth 2 and a check on the PARENT's name, so the only files this loop can
    # ever see are `<state>\<index>\request\<name>`. A slot may create entries in
    # its own request directory and nowhere else, and a directory it creates in
    # there puts its contents at depth 3, out of reach. The walk does not follow a
    # junction either: Get-ChildItem -Recurse does not descend a reparse point
    # without -FollowSymlink, the same property Test-CacheTreeHostile relies on.
    $requests = @()
    try {
        $requests = @(Get-ChildItem -Path $StateRoot -Filter '*' -File -Recurse -Depth 2 `
                -ErrorAction SilentlyContinue | Where-Object { $_.Directory.Name -ceq 'request' })
    } catch { $null = $_ }

    foreach ($request in ($requests | Sort-Object -Property LastWriteTimeUtc)) {
        $index = Get-RequestSlotIndex -Path $request.FullName
        $name = $request.Name
        # Deleted BEFORE it is acted on. A request that keeps failing must not be
        # a request that keeps being served: the slot's next gate fails, which is
        # the outcome a stuck reset is supposed to have.
        try { Remove-Item -LiteralPath $request.FullName -Force -ErrorAction Stop } catch { $null = $_ }
        if ($index -eq '') { continue }
        if (-not (Test-ResetRequestName -Name $name)) {
            Write-ResetLog "slot $index asked for '$name', which is not a request -- ignored"
            continue
        }
        try {
            if ($name -ceq 'started') {
                Invoke-SlotGate -Index ([int] $index)
            } else {
                Invoke-SlotReset -Index ([int] $index)
            }
        } catch {
            # Never fatal. A service that exits here is a host on which every
            # later job fails its gate, and the shim would restart it into the
            # same request it just deleted.
            Write-ResetLog "slot $index '$name' failed -- $($_.Exception.Message)"
        }
    }
    Start-Sleep -Seconds $PollSeconds
}
'@
    $body = $body.Replace('@STATE_ROOT@', $StateRoot)
    $body = $body.Replace('@TEMPLATE_ROOT@', $TemplateRoot)
    $body = $body.Replace('@LOG_PATH@', $LogPath)
    $body = $body.Replace('@QUIESCE_SECONDS@', [string] $QuiesceWaitSeconds)
    return $body.Replace('@COPY_SECONDS@', [string] $CopySeconds)
}

function Get-JobHookScript {
    <#
      .SYNOPSIS
        The body of one end of the per-job slot reset hook.
      .DESCRIPTION
        THE FAULT THIS EXISTS FOR IS NOT gcloud-SPECIFIC AND WAS PAID FOR ON LINUX

        This used to delete `%APPDATA%\gcloud` and `%APPDATA%\gsutil`. A denylist
        of two directories cannot support the claim the reset is read to make --
        that the next job inherits nothing -- because a Windows profile carries the
        same executable surfaces Linux does under other names: a `.gitconfig` that
        names a core.hooksPath, both PowerShell profiles, any writable directory on
        PATH, the previous checkout's own `.git\hooks`, and whatever the next tool
        decides a credential store is. Linux retired the equivalent hook in #110
        and replaced it in #231 and #237; docs/adr-windows-pool.md phase 4 is the
        Windows version of that decision and #232 is the issue.

        So the hooks stopped deleting. What they do now is ASK, and the deleting is
        done by a service running as SYSTEM outside the job -- which is what buys
        the property the old hook could never have, since a profile cannot be
        replaced while a process is running as the account that owns it.

        TWO ENDS, TWO FILES, TWO DIFFERENT JOBS

          * STARTED writes a `started` request and WAITS for a verdict, failing the
            job unless it is `clean`. A slot whose predecessor never finished has
            no marker, so its next job is failed rather than run.
          * COMPLETED writes a `completed` request and returns immediately. It must
            not wait: the work it is asking for stops the service it is running
            under, and waiting for that is waiting to be killed. Serialisation is
            free rather than engineered -- while the reset holds the runner service
            stopped, the agent cannot be dispatched a job.

        The account database, again and for the same reason: which slot to ask for
        is taken from the identity this hook is RUNNING AS, not from an environment
        variable a job can set. A request written into another slot's directory is
        an Access is denied, because phase 4 grants write on `<state>\<i>\request`
        to `ci-s<i>` alone -- but a hook that asked on the wrong slot's behalf would
        be a job resetting a neighbour that is mid-work, so it is refused here too.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Started', 'Completed')][string] $Phase,
        [string] $StateRoot = $script:StateRoot,
        [int] $WaitSeconds = $script:SlotResetWaitSeconds,
        [int] $PollSeconds = $script:SlotResetPollSeconds
    )

    # Single-quoted here-strings with @TOKEN@ placeholders, so the hook reads on
    # disk exactly as it reads here and the substitutions are all in one place.
    $preamble = @'
# Installed by windows-host-startup.ps1 (phase 4). Runs as the slot user at one
# end of every job. See Get-JobHookScript for why the two ends differ.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The identity, not $env:USERNAME and not $env:USERPROFILE: this runs inside the
# job's environment and which slot is being reset is the host's decision.
$who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$leaf = ($who -split '\\')[-1]
# Matched POSITIVELY, so the capture is read from a comparison that succeeded.
# `-notmatch` also fills $Matches when the regex matched, which is exactly the
# kind of thing that keeps working until somebody reorders the branches.
if ($leaf -match '^ci-s([0-9]+)$') {
    $index = $Matches[1]
} else {
    [Console]::Error.WriteLine("slot reset: refusing to act as '$who' -- not a slot account")
    exit 1
}
$state = Join-Path '@STATE_ROOT@' $index
$request = Join-Path (Join-Path $state 'request') '@REQUEST@'
'@

    if ($Phase -eq 'Completed') {
        $tail = @'

# No wait, by design: the reset this asks for stops the service this hook is
# running under. A failure to ask is still fatal -- an unasked reset is a slot
# that keeps the last job's profile, and its next gate is what will say so.
New-Item -ItemType File -Path $request -Force | Out-Null
exit 0
'@
    } else {
        $tail = @'

$verdict = Join-Path $state 'verdict'

# The timestamp is taken from the request FILE, not from the clock: the verdict
# and the request are written to the same volume, and a verdict older than the
# request is the last job's, sitting there since before this one asked.
New-Item -ItemType File -Path $request -Force | Out-Null
$asked = (Get-Item -LiteralPath $request).LastWriteTimeUtc

$deadline = (Get-Date).AddSeconds(@WAIT@)
while ($true) {
    $item = $null
    try { $item = Get-Item -LiteralPath $verdict -ErrorAction Stop } catch { $null = $_ }
    if ($item -and $item.LastWriteTimeUtc -ge $asked) {
        $text = ''
        try { $text = [string] (Get-Content -Raw -LiteralPath $verdict -ErrorAction Stop) } catch { $null = $_ }
        # `clean`, case-sensitively and in full. Every loose spelling of this
        # comparison is a way of saying yes to something that did not happen.
        if ($text.Trim() -ceq 'clean') { exit 0 }
        [Console]::Error.WriteLine("slot reset: this slot is not clean (verdict '$($text.Trim())')")
        exit 1
    }
    if ((Get-Date) -ge $deadline) { break }
    Start-Sleep -Seconds @POLL@
}
# A job that could not be given a clean slot must not run on a dirty one. This is
# the same trade the credential hook made, now over the whole profile.
[Console]::Error.WriteLine('slot reset: no verdict in @WAIT@ s -- refusing to run on an unproved slot')
exit 1
'@
    }

    $text = ($preamble + $tail).Replace('@STATE_ROOT@', $StateRoot)
    $text = $text.Replace('@REQUEST@', $Phase.ToLowerInvariant())
    $text = $text.Replace('@WAIT@', [string] $WaitSeconds)
    return $text.Replace('@POLL@', [string] $PollSeconds)
}

function Get-SlotCachePath {
    <#
      .SYNOPSIS
        Where slot $Index's own writable dependency cache lives. Pure.
      .DESCRIPTION
        -Root is injectable for the reason Get-SlotTempPath's is: the Pester suite
        runs on ubuntu-latest, where `Join-Path 'C:\ci\cache' 1` does not build a
        string, it throws DriveNotFoundException.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [string] $Root = $script:CacheSlots
    )
    return (Join-Path $Root ([string] $Index))
}

function Get-CacheHostileReason {
    <#
      .SYNOPSIS
        Why the master cache must not be sealed or copied, or '' if it may be. Pure.
      .DESCRIPTION
        The Windows half of host-startup.sh's cache_master_is_hostile(). The Linux
        scan refuses symlinks, device nodes, setuid bits, out-of-tree hardlinks
        and file capabilities; three of those five spellings do not exist here.
        This function is the REPARSE POINT half. The out-of-tree hardlink is the
        other half and lives in Get-CacheHardlinkReason, because it cannot be
        decided from a DirectoryInfo: it takes a link count, and reading one
        takes a handle.

        It is refused because of what the two operations after this scan would do
        with it, which is the same test the Linux list is built from:

          * SEALING walks the tree and applies an ACL. `icacls /reset /T` and an
            inheritable ACE both follow a junction, so a junction aimed at
            C:\Windows or at another slot's workspace is a grant applied THERE --
            read-and-execute for every slot account, on a tree nobody chose to
            share. An ACL applied to the wrong tree is not undone by the next
            boot; it is the durable half of this failure.
          * COPYING follows it too. robocopy without /SJ and /SL descends into a
            junction and copies what it points at, so the same junction turns a
            per-slot cache seed into a per-slot copy of whatever tree it names --
            silently, and K times.

        The master is repo-supplied content: `warm_cache_script` is arbitrary code
        the consuming repository supplies, running elevated in the build VM. That
        makes this a gate over untrusted build input, not decoration -- exactly as
        README.md puts it for Linux, "a warm cache is untrusted build input".

        Takes already-enumerated entries rather than doing the enumeration, so the
        rule is asserted by a test that never touches an NTFS volume. The caller
        passes the ROOT ITSELF as the first entry: a master that is a junction is
        the case where every entry below it is already the wrong tree, and a scan
        that only looked at children would walk into it to find out.

        Returns the FIRST reason, not all of them, and names the entry. Six
        predicates sharing one message is the thing the Linux side had to go back
        and fix -- a live host shipped a setgid /opt/ci-cache and the refusal named
        the path twice and the cause not at all -- so this one says which attribute
        on which path from the start.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][array] $Entries)

    foreach ($entry in $Entries) {
        if ($null -eq $entry) { continue }
        $attrs = [string] $entry.Attributes
        if ($attrs -match 'ReparsePoint') {
            # The name is untrusted text, for the same reason the Linux packer
            # gate runs its refusal through `tr`: a path may hold a newline, and a
            # refusal that splits into two lines can be shaped to read like any
            # other line this boot log emits. Control characters out, one line,
            # bounded length.
            $safe = ([string] $entry.FullName) -replace '[\x00-\x1f]', ' '
            if ($safe.Length -gt 300) { $safe = $safe.Substring(0, 300) }
            return "reparse point: $safe"
        }
    }
    return ''
}

# The hardlink probe's P/Invoke source.
#
# WHY THERE HAS TO BE ONE. A file's security descriptor lives on its MFT record,
# not on the directory entry, so every NAME for a file shares ONE ACL. The seal
# that runs after the scan above is `icacls /reset /T` followed by an
# inheritable grant, and `/T` walks names -- each name it touches rewrites the
# descriptor of the underlying file. A hardlink dropped at C:\ci-cache\npm\x
# pointing at a file under C:\Windows is therefore a grant applied THERE, at the
# real path, and an ACL applied to the wrong tree is not undone by the next boot.
# robocopy then copies the content into every slot, which is the smaller half.
#
# It is the same failure as the reparse point and it was not covered, because
# detecting it needs a LINK COUNT and nothing in the managed API surface
# available to Windows PowerShell 5.1 exposes one. `Get-ChildItem` does not,
# FileInfo.LinkTarget is .NET 6, and `fsutil hardlink list` is one process per
# file over a tree of tens of thousands. GetFileInformationByHandle is one call.
#
# FILE_READ_ATTRIBUTES (0x80) and nothing more: the probe never needs the
# contents, and an attributes-only open is the cheapest handle Windows will give.
# FILE_FLAG_OPEN_REPARSE_POINT (0x00200000) so the probe judges the name in the
# tree rather than whatever it points at -- the scan above refuses reparse points
# outright, and this must not disagree with it about which file it is looking at.
# Full sharing (7), because a file another process holds open is not evidence of
# anything and a sharing violation here would read as an unscannable tree.
$script:CacheLinkProbeSource = @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct BY_HANDLE_FILE_INFORMATION {
    public uint FileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
}
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(
    string lpFileName, uint dwDesiredAccess, uint dwShareMode, System.IntPtr lpSecurityAttributes,
    uint dwCreationDisposition, uint dwFlagsAndAttributes, System.IntPtr hTemplateFile);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetFileInformationByHandle(
    Microsoft.Win32.SafeHandles.SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);
'@

# $null until the probe has been attempted; $true or $false afterwards.
$script:CacheLinkProbeReady = $null

function Initialize-CacheLinkProbe {
    <#
      .SYNOPSIS
        Compile the link-count P/Invoke. $true when the probe may be used.
      .DESCRIPTION
        LAZY, AND THAT IS THE COST ARGUMENT. Add-Type shells out to csc.exe --
        measured at 0.5-0.9s on Windows PowerShell 5.1 -- and a host with no
        snapshot to hydrate must not pay it. It is called from the hydrate, after
        a staged tree exists to scan, and never from the boot path that reads the
        baked master: that tree was scanned once at image build, where the cost is
        paid per image rather than per host.

        Compiled ONCE. The guard is the type's existence rather than the flag
        alone, because a second Add-Type of the same namespace throws on a name
        that is already loaded, and the throw would arrive as a hydrate failure.

        Never Deny-Boot. A probe that will not compile is a snapshot this host
        cannot scan, which costs it a warm cache and nothing else.
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:CacheLinkProbeReady) { return $script:CacheLinkProbeReady }
    $script:CacheLinkProbeReady = $false
    try {
        if (-not ([System.Management.Automation.PSTypeName] 'CiCache.Fs').Type) {
            Add-Type -Namespace 'CiCache' -Name 'Fs' -MemberDefinition $script:CacheLinkProbeSource
        }
        $script:CacheLinkProbeReady = $true
    } catch {
        Write-BootLog "phase 7: the hardlink probe did not compile: $($_.Exception.Message)"
    }
    return $script:CacheLinkProbeReady
}

function Get-CacheLinkRecord {
    <#
      .SYNOPSIS
        One record per multi-named file under a scanned tree. Bounded.
      .DESCRIPTION
        Takes the entries Get-CacheStagedEntry already walked rather than walking
        again: the second enumeration would double the cost of the one step of
        phase 7 that is measured in tens of thousands of file-system calls.

        ONLY FILES WITH MORE THAN ONE NAME ARE RECORDED. A tree of a hundred
        thousand singly-named files produces an empty list, and the predicate that
        reads it then has nothing to do. That matters because the interesting case
        is rare and the walk is not.

        The identity is (volume serial, file index high, file index low) -- the
        Windows spelling of (device, inode). Two names of one file agree on it and
        no two files do, which is the whole basis of the count below.

        BOUNDED LIKE EVERYTHING ELSE IN PHASE 7, and `TimedOut` returns no records
        at all. Half a list of names is worse than none here: the predicate
        compares how many names it SAW against how many the file has, so a walk cut
        short reports every multi-named file as out-of-tree and refuses a snapshot
        that was fine.

        `Failed` counts handles that would not open or would not answer. As
        LocalSystem, on a tree this host just unpacked, neither should happen --
        and a file whose attributes cannot be read is exactly the file a scan must
        not report as clean.

        Measured 2026-08-23 on Windows PowerShell 5.1 over NTFS: 0.17ms per file
        warm and 1.4ms cold. The staged tree is warm by construction -- this host
        wrote it seconds earlier -- so a 60k-file snapshot costs around 10s of the
        60s budget, and the deadline covers the case where it does not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][array] $Entries,
        [Parameter(Mandatory = $true)][datetime] $DeadlineUtc
    )

    $records = New-Object System.Collections.ArrayList
    $failed = 0

    foreach ($entry in $Entries) {
        if ($null -eq $entry -or $entry.PSIsContainer) { continue }
        if ([datetime]::UtcNow -gt $DeadlineUtc) {
            return [pscustomobject] @{ Records = @(); Failed = $failed; TimedOut = $true }
        }
        # \\?\ so a path past MAX_PATH is probed rather than counted as a failure:
        # a deep node_modules tree is the ordinary case here, not the exotic one.
        $handle = [CiCache.Fs]::CreateFileW(('\\?\' + $entry.FullName), 0x80, 7, [System.IntPtr]::Zero, 3, 0x00200000, [System.IntPtr]::Zero)
        if ($handle.IsInvalid) {
            $handle.Dispose()
            $failed++
            continue
        }
        try {
            $info = New-Object 'CiCache.Fs+BY_HANDLE_FILE_INFORMATION'
            if (-not [CiCache.Fs]::GetFileInformationByHandle($handle, [ref] $info)) {
                $failed++
                continue
            }
            if ($info.NumberOfLinks -gt 1) {
                [void] $records.Add([pscustomobject] @{
                        Path  = [string] $entry.FullName
                        Links = [int] $info.NumberOfLinks
                        Id    = ('{0}:{1}:{2}' -f $info.VolumeSerialNumber, $info.FileIndexHigh, $info.FileIndexLow)
                    })
            }
        } finally {
            $handle.Dispose()
        }
    }
    return [pscustomobject] @{ Records = $records.ToArray(); Failed = $failed; TimedOut = $false }
}

function Get-CacheHardlinkReason {
    <#
      .SYNOPSIS
        Why a tree's hardlinks make it unsafe to seal or copy, or '' if they do
        not. Pure.
      .DESCRIPTION
        COUNTED RATHER THAN FORBIDDEN, and that is the whole design. The Linux
        scan spent a release refusing every tree with a link count above one, and
        it had to be taken back out: pnpm's content-addressed store hardlinks
        internally, `cp -al` in a warm script does too, and both are entirely
        safe -- every name is inside the tree, so the ACL walk reaches all of
        them. Over-blocking a security check into permanent uselessness is worse
        than not having it, because the pool then runs cold on every boot and
        nobody watches a cache-hit rate per job.

        The exact question is answerable: count how many of a file's names live
        inside the tree and compare with how many names it has. Equal means the
        seal reaches all of them. Fewer means at least one name is somewhere this
        tree does not own -- and `icacls /reset /T` rewrites the descriptor of the
        file, not of the name, so the grant lands at that other path.

        Deterministic on the offender it names: the records are re-read IN ORDER
        rather than the count table being enumerated, because a hashtable's order
        is unspecified and a refusal that names a different file each run is a
        refusal nobody can act on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][array] $Records)

    $seen = @{}
    foreach ($record in $Records) {
        if ($null -eq $record) { continue }
        $id = [string] $record.Id
        if ($seen.ContainsKey($id)) { $seen[$id] = $seen[$id] + 1 } else { $seen[$id] = 1 }
    }
    foreach ($record in $Records) {
        if ($null -eq $record) { continue }
        $id = [string] $record.Id
        $links = [int] $record.Links
        if ($seen[$id] -ge $links) { continue }
        # Same treatment as the reparse-point refusal: the name is untrusted text
        # that may hold a newline, and a refusal which splits into two lines can be
        # shaped to read like any other line this boot log emits.
        $safe = ([string] $record.Path) -replace '[\x00-\x1f]', ' '
        if ($safe.Length -gt 300) { $safe = $safe.Substring(0, 300) }
        return "out-of-tree hardlink ($($seen[$id]) of $links names are in the tree): $safe"
    }
    return ''
}

function Test-RobocopySuccess {
    <#
      .SYNOPSIS
        Whether a robocopy exit code means the copy happened. Pure.
      .DESCRIPTION
        ROBOCOPY DOES NOT RETURN 0 ON SUCCESS, AND THAT IS THE WHOLE OF THIS
        FUNCTION

        Its exit code is a BITMAP: 1 = files copied, 2 = extra files in the
        destination, 4 = mismatched files, 8 = some files could not be copied,
        16 = a serious error, no files copied. So the ordinary successful seed of
        a non-empty tree exits 1, and `if ($LASTEXITCODE -ne 0)` -- the check every
        other native call in this file makes, correctly -- would treat every
        successful copy as a failure and every slot would run cold while the log
        said the copy failed.

        Below 8 is success, 8 and above is failure. Written as a comparison rather
        than a bit test because 16 is not a flag combined with the others: robocopy
        reports it alone, and `-band 8` would pass a 16.

        A NEGATIVE code is a failure too, and it is not hypothetical -- a killed or
        crashed robocopy exits with the NTSTATUS as a negative integer, and `-lt 8`
        is true for every one of them. That is the check this function exists to
        stop somebody writing inline in one line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $ExitCode)
    return ($ExitCode -ge 0 -and $ExitCode -lt 8)
}

function Test-CacheSeedBudgetExpired {
    <#
      .SYNOPSIS
        Whether phase 7 has spent its seeding budget. Pure.
      .DESCRIPTION
        A budget of zero or less reads as ALREADY EXPIRED rather than as "no
        limit". The two readings are both defensible and only one of them is
        safe: a bound that silently means unbounded is the failure this exists to
        prevent, and the cost of the other mistake is a cold cache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double] $ElapsedSeconds,
        [Parameter(Mandatory = $true)][double] $BudgetSeconds
    )
    if ($BudgetSeconds -le 0) { return $true }
    return ($ElapsedSeconds -ge $BudgetSeconds)
}

function Get-CacheSeedSecondsLeft {
    <#
      .SYNOPSIS
        Whole seconds left in phase 7's budget. Never negative. Pure.
      .DESCRIPTION
        This is what bounds a single native call. Test-CacheSeedBudgetExpired
        answers "may another copy start", which is only ever asked BETWEEN calls;
        a call already running is answerable by nothing, so each one is given the
        time that is left and killed when it is gone. The floor is 0 rather than
        a small positive number on purpose: a call given 0 seconds is not started
        at all, which is the correct behaviour once the budget is spent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double] $ElapsedSeconds,
        [Parameter(Mandatory = $true)][double] $BudgetSeconds
    )
    $left = [int] [math]::Floor($BudgetSeconds - $ElapsedSeconds)
    if ($left -lt 0) { return 0 }
    return $left
}

function Format-NativeErrorText {
    <#
      .SYNOPSIS
        One log-safe line out of a native command's stderr. Pure.
      .DESCRIPTION
        Control characters folded to spaces and the result capped, for the reason
        the master scan caps $scanErrors: this text comes from a tool reporting on
        a tree job code could have written, so it is attacker-influenced input on
        its way into the boot log, and a boot log is read with the eye rather than
        with a parser. The first non-empty line is the one that names the cause;
        the rest of an icacls or robocopy failure is per-file repetition.
    #>
    [CmdletBinding()]
    param([string] $Text)
    if (-not $Text) { return '' }
    foreach ($line in ($Text -split "`r?`n")) {
        $clean = ($line -replace '[\x00-\x1f]', ' ').Trim()
        if (-not $clean) { continue }
        if ($clean.Length -gt 300) { $clean = $clean.Substring(0, 300) }
        return $clean
    }
    return ''
}

function Test-CacheSeedAffordable {
    <#
      .SYNOPSIS
        Whether one more copy of the master still leaves the volume room. Pure.
      .DESCRIPTION
        Checked before EACH slot's copy, not once for the host, because the answer
        changes as the copies land: on a host where two of four copies fit, seeding
        two slots and leaving two cold is strictly better than either filling the
        volume or refusing all four.

        A cache is not a workspace: running out of disk mid-copy leaves a partial
        tree that reads as a cache and misses on every entry that did not arrive,
        and it fails the OTHER slots' jobs -- which a cold cache never does. Hence
        a floor rather than "copy while anything is left".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][long] $MasterBytes,
        [Parameter(Mandatory = $true)][long] $FreeBytes,
        [Parameter(Mandatory = $true)][long] $FloorBytes
    )
    return (($FreeBytes - $MasterBytes) -ge $FloorBytes)
}

function Get-SlotCacheEnvironment {
    <#
      .SYNOPSIS
        The variables that point one slot's build tools at its own cache. Pure.
      .DESCRIPTION
        Every entry is the variable the tool's own documentation names, and the
        list is deliberately the same one host-startup.sh's cache_env() emits, with
        the same two EXCLUSIONS -- each a bug avoided rather than an oversight:

          * GOCACHE (Go's BUILD cache) -- golang/go#43645: concurrent builds
            sharing one GOCACHE is not safe. GOMODCACHE is a different directory
            and is the one worth keeping warm, so only that is set.
          * RUNNER_TOOL_CACHE / AGENT_TOOLSDIRECTORY -- the tool-cache library has
            no locking (actions/toolkit#804), and the setup-* actions treat that
            directory as one they own and prune. It stays per-slot and untouched.

        Returns an ordered dictionary for the reason Get-SlotServiceEnvironment
        returns one: the service key phase 5 writes has to be comparable across two
        boots of one host.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $CachePath)

    $root = $CachePath.TrimEnd('\')
    return [ordered] @{
        # npm reads any config key from a matching npm_config_* variable.
        npm_config_cache      = "$root\npm"
        YARN_CACHE_FOLDER     = "$root\yarn"
        # BOTH spellings, because the supported one changed: pnpm 11 reads
        # pnpm_config_store_dir and silently IGNORES the npm_config_ form it
        # honoured before. Repositories pin their own pnpm, so this host cannot
        # assume which side of that change it is serving.
        pnpm_config_store_dir = "$root\pnpm-store"
        npm_config_store_dir  = "$root\pnpm-store"
        GOMODCACHE            = "$root\go-mod"
        PIP_CACHE_DIR         = "$root\pip"
        UV_CACHE_DIR          = "$root\uv"
        # Maven has no environment variable for the local repository; the system
        # property is the supported route and MAVEN_ARGS is how you deliver one
        # from the environment (Maven 3.9.0 and later). A repository that sets its
        # own MAVEN_ARGS overrides this, which is the correct precedence.
        MAVEN_ARGS            = "-Dmaven.repo.local=$root\m2"
        NUGET_PACKAGES        = "$root\nuget"
        COMPOSER_CACHE_DIR    = "$root\composer"
    }
}

function Get-SlotServiceEnvironment {
    <#
      .SYNOPSIS
        The environment block phase 5 writes onto one slot's runner service.
      .DESCRIPTION
        Per SERVICE, never machine-wide. A machine-wide TMP would hand every slot
        the same one, which is the collision the per-slot directory exists to
        remove; machine-wide GCE_METADATA_* would point the host's own tooling at
        the broker.

        ALL FIVE VALUES ARE SET UNCONDITIONALLY, AND THAT IS THE POINT OF THIS
        FUNCTION

        The tempting shape makes both halves conditional on there being a broker,
        since all five are "credential plumbing". That is exactly wrong, and it
        is wrong twice. A pool with no job service account is the pool where an
        inherited or ambient credential is MOST dangerous: nothing on the host
        competes with whatever the last workflow left behind, so the leftover is
        simply what the next job authenticates as.

        The hooks get the leftover replaced, wholesale, by the reset service that
        runs outside the job (phase 4). The GCE_METADATA_* values close the other
        door -- unset, they do not withhold credentials, they hand ADC back to
        169.254.169.254 and the HOST service account, because section 3A deleted
        the fence that gives Linux that property for free. Phase 3 hands this
        function the closed endpoint for exactly that reason.

        Returns an ordered dictionary so the block phase 5 writes is stable, which
        is what makes a service key comparable across two boots of one host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        # TWO paths, and they must not be collapsed back into one. The runner does
        # not tell a hook which end of the job it is at, so one file serving both
        # would have to guess -- and the two ends are a gate that waits and a reset
        # request that must not.
        [string] $StartedHookPath = $script:JobHookStartedPath,
        [string] $CompletedHookPath = $script:JobHookCompletedPath,
        [AllowEmptyString()][string] $BrokerEndpoint = '',
        # The slot's own dependency cache, or '' when phase 7 could not give it
        # one. See the block at the end of this function for why this is the one
        # value here that is allowed to be conditional.
        [AllowEmptyString()][string] $CachePath = '',
        # The host's affinity label, `host-<instance-name>`. Phase 5 always has
        # one -- Read-Config denies the boot on an unnamed instance -- so the
        # empty default exists for the suite, not for a host.
        [AllowEmptyString()][string] $HostLabel = '',
        # Injectable for the same reason Get-SlotTempPath's is: the Pester suite
        # runs on ubuntu-latest, where `Join-Path 'C:\ci\slots' 1` does not build
        # a string, it throws DriveNotFoundException. A pure function that cannot
        # be called off Windows is a pure function nothing tests.
        [string] $SlotRoot = $script:SlotRoot
    )

    $temp = Get-SlotTempPath -Index $Index -Root $SlotRoot
    $block = [ordered] @{
        TMP  = $temp
        TEMP = $temp
    }

    # What makes gcloud, google-auth and the Go and Java clients find the broker
    # instead of the real metadata server -- and, on a pool with no broker, what
    # makes them find NOTHING instead of the host identity. Never omitted: an
    # unpointed client on Windows is not an unauthenticated one.
    $endpoint = $BrokerEndpoint
    if ([string]::IsNullOrWhiteSpace($endpoint)) { $endpoint = $script:ClosedMetadataEndpoint }
    $block['GCE_METADATA_HOST'] = $endpoint
    $block['GCE_METADATA_IP'] = $endpoint
    $block['GCE_METADATA_ROOT'] = $endpoint

    $block['ACTIONS_RUNNER_HOOK_JOB_STARTED'] = $StartedHookPath
    $block['ACTIONS_RUNNER_HOOK_JOB_COMPLETED'] = $CompletedHookPath

    # The label the rest of a workflow run pins itself to, read by the anchor
    # job (docs/adr-pr-host-affinity.md). Absent, the anchor runs the workflow
    # unpinned -- a degradation, not a failure, which is why this one is allowed
    # to be conditional where the five above are not.
    if (-not [string]::IsNullOrWhiteSpace($HostLabel)) {
        $block['CI_HOST_LABEL'] = $HostLabel
    }

    # THE ONE CONDITIONAL BLOCK, AND THE CONTRAST WITH THE FIVE ABOVE IS THE POINT
    #
    # The five above are set whatever the host looks like, because an unset
    # GCE_METADATA_HOST does not withhold a credential -- it hands ADC back to the
    # real metadata server and the HOST service account. Omission there is a
    # weaker boundary, so omission is not allowed.
    #
    # These ten are the opposite. An unset npm_config_cache means npm uses its
    # own default under the slot's profile: a cache that is cold and entirely
    # correct. Pointing them at a directory phase 7 did not finish building would
    # be the harmful move -- a tool that cannot open the cache it was told to use
    # fails the job rather than missing. So the absence of a cache is expressed by
    # saying nothing, and phase 7 hands '' for exactly the slots it could not
    # serve.
    if (-not [string]::IsNullOrWhiteSpace($CachePath)) {
        foreach ($entry in (Get-SlotCacheEnvironment -CachePath $CachePath).GetEnumerator()) {
            $block[$entry.Key] = $entry.Value
        }
    }
    return $block
}

function Get-ServiceEnvironmentValue {
    <#
      .SYNOPSIS
        One slot's environment block as the REG_MULTI_SZ the SCM reads. Pure.
      .DESCRIPTION
        A service's per-service environment is the `Environment` value under its
        own key, a REG_MULTI_SZ of `NAME=VALUE` strings. Built here rather than
        inline so the two ways it can be silently wrong are asserted by a test:

          * a NAME that is not an environment variable name. The values reaching
            this come from Get-SlotServiceEnvironment, but the block is the last
            thing standing between instance metadata and a service that starts as
            a local account, and section 3A accepts that a Windows host cannot
            assume its metadata is untampered.
          * a VALUE carrying CR, LF or NUL. REG_MULTI_SZ is NUL-delimited, so an
            embedded NUL does not corrupt the write -- it TRUNCATES the block at
            that entry, and every variable after it silently disappears. On this
            block the entries that would disappear are the reset hooks.

        Both throw rather than sanitise. A registration this cannot describe
        exactly is a registration that must not happen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Environment)

    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Environment.Keys) {
        $name = [string] $key
        $value = [string] $Environment[$key]
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "refusing to build a service environment block: '$name' is not an environment variable name"
        }
        if ($value -match "[`r`n`0]") {
            throw ("refusing to build a service environment block: the value of $name carries a " +
                'newline or a NUL, which would truncate every entry after it')
        }
        $entries.Add("$name=$value")
    }
    return $entries.ToArray()
}

function Test-ServiceLogonAccount {
    <#
      .SYNOPSIS
        Does a service's configured StartName name this slot's account? Pure.
      .DESCRIPTION
        The SCM reports a local account as `.\ci-s1`, and there are three other
        spellings of the same account -- bare `ci-s1`, `<HOST>\ci-s1`, and the
        `.\` form with different casing -- so a plain equality test against the
        name phase 1 created reports a correctly configured service as wrong.

        Everything ELSE must be rejected, and the ones that matter are the SCM
        defaults this whole sequence exists to displace: LocalSystem,
        `NT AUTHORITY\NetworkService` and `NT AUTHORITY\LocalService` are
        machine-wide, shared by every slot, and each of them is what the service
        runs as if the identity change silently did nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $StartName,
        [Parameter(Mandatory = $true)][string] $SlotUser
    )

    if ([string]::IsNullOrWhiteSpace($StartName)) { return $false }
    $account = $StartName.Trim()
    # Whatever precedes the last backslash is a machine or authority name; the
    # account itself is what follows it. `.\ci-s1` and `WIN-ABC\ci-s1` both
    # reduce to `ci-s1`, and `NT AUTHORITY\NetworkService` reduces to
    # `NetworkService`, which is not a slot user and so fails the comparison.
    $leaf = $account.Substring($account.LastIndexOf('\') + 1)
    return ($leaf -eq $SlotUser)
}

function Get-RedactedLine {
    <#
      .SYNOPSIS
        One captured output line with a known secret struck out of it. Pure.
      .DESCRIPTION
        config.cmd does not echo its --token today, and the boot log is
        SYSTEM-and-Administrators-only while the serial console sits behind
        project IAM. This exists so that none of those three sentences has to
        stay true forever: the redaction is the only one of them this repository
        controls.

        A literal replace, not a regex, because the secret is not a pattern and
        a pattern is what would miss it. An empty or absent secret returns the
        line unchanged rather than redacting everything -- '' is a substring of
        every string, and a log of nothing but asterisks is how a boot stops
        being diagnosable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Line,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Secret
    )

    if ([string]::IsNullOrEmpty($Line)) { return '' }
    if ([string]::IsNullOrWhiteSpace($Secret)) { return $Line }
    return $Line.Replace($Secret, '***')
}

function Get-RunnerServiceName {
    <#
      .SYNOPSIS
        The runner service name from the agent's own `.service` marker. Pure.
      .DESCRIPTION
        `config.cmd --runasservice` records the service it installed in a
        `.service` file in the runner directory; that file, not a name this script
        reconstructs, is the answer. Reconstructing it would mean encoding
        GitHub's naming scheme here, and a scheme that changes upstream would
        leave phase 5 configuring the environment and the recovery policy of a
        service that does not exist -- while the agent that DOES exist starts with
        neither, takes jobs, and restarts itself out of a cordon.

        VALIDATED TWICE, because the file is inside a directory the slot account
        can write and the name it holds reaches sc.exe, Start-Service and an HKLM
        service key:

          * shape -- literally `actions.runner.<...>`, refused rather than
            escaped;
          * OWNERSHIP -- the name must end in this slot's own agent name.
            GitHub's scheme is `actions.runner.<owner>-<repo>.<agent>` and the
            agent name is `<instance>-s<i>`, unique per slot on this host. Shape
            alone accepts any well-formed name, and a stale or restored `.service`
            from a previous boot or a sibling slot would then send this slot's
            logon account, environment block and recovery policy at ANOTHER
            slot's already-registered service. Suffix, not equality: the owner and
            repo halves are sanitised upstream and this file does not get to
            encode how.

        Returns '' on anything it will not vouch for; the caller denies the boot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Marker,
        [Parameter(Mandatory = $true)][string] $AgentName
    )

    if ([string]::IsNullOrWhiteSpace($Marker)) { return '' }
    $name = $Marker.Trim()
    if ($name -notmatch '^actions\.runner\.[A-Za-z0-9._-]+$') { return '' }
    if (-not $name.EndsWith(".$AgentName", [StringComparison]::Ordinal)) { return '' }
    return $name
}

function Get-RunnerConfigArgument {
    <#
      .SYNOPSIS
        The config.cmd argument list for one slot, WITHOUT the token. Pure.
      .DESCRIPTION
        The token is appended by the caller and is deliberately not a parameter
        here: a pure function that never receives the credential cannot leak it
        into a test fixture, a log line or an error message, and this is the one
        function in phase 5 a test calls directly.

        --disableupdate transfers verbatim from Linux and matters MORE here.
        GitHub otherwise forces a runner self-update that leaves the process alive
        while the agent is offline and undispatchable -- 90 minutes of stalled CI
        on the pool this replaces -- and on a warm host that takes K slots down at
        once instead of one short-lived VM. The image pins the agent version;
        upgrades ship by rebuilding the image, which is reviewable.

        --replace, because a host that rebooted has an agent of this name already
        in GitHub's list and a refused registration is a slot that never comes
        back.

        --runasservice with NO account flags. The ADR's sketch passes the pair of
        logon-account flags config.cmd accepts, and the password one of them takes
        is a PLAINTEXT argument -- in the process table of a host whose local
        accounts run pull-request code. The service is installed under the SCM
        default instead and its logon account is changed afterwards through
        ChangeServiceConfigW, which takes the password as unmanaged memory
        marshalled straight out of the SecureString. See Grant-ServiceLogonAccount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Owner,
        [Parameter(Mandatory = $true)][string] $Repo,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Labels,
        [Parameter(Mandatory = $true)][string] $WorkPath,
        [AllowEmptyString()][string] $RunnerGroup = ''
    )

    $configArgs = [System.Collections.Generic.List[string]]::new()
    $configArgs.AddRange([string[]] @('--unattended', '--replace', '--disableupdate', '--runasservice'))
    $configArgs.AddRange([string[]] @('--url', "https://github.com/$Owner/$Repo"))
    $configArgs.AddRange([string[]] @('--name', $Name))
    $configArgs.AddRange([string[]] @('--work', $WorkPath))
    if (-not [string]::IsNullOrWhiteSpace($Labels)) {
        $configArgs.AddRange([string[]] @('--labels', $Labels.Trim()))
    }
    if (-not [string]::IsNullOrWhiteSpace($RunnerGroup)) {
        $configArgs.AddRange([string[]] @('--runnergroup', $RunnerGroup.Trim()))
    }
    return $configArgs.ToArray()
}

function Get-SlotAgentName {
    <#
      .SYNOPSIS
        The agent name slot <Index> registers under. Pure.
      .DESCRIPTION
        `<instance>-s<i>`, and it is not cosmetic: `orphan_decision()` on the
        controller parses this name back to an instance, so a rename here silently
        un-reaps every Windows registration -- the agent stays in GitHub's list,
        the host it named is long gone, and nothing in the controller notices
        because nothing can.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstanceName,
        [Parameter(Mandatory = $true)][int] $Index
    )
    return "$InstanceName-s$Index"
}

# --- phase 6: the boot probe, pure half ---------------------------------------
#
# ASSERT THE CAPABILITY, NOT THE DAEMON -- AND, HERE, ASSERT ITS ABSENCE
#
# Section 3A of the ADR deleted the metadata fence, so the old probe's central
# claim -- "a slot user cannot reach the token endpoint" -- is not a property
# this design has, and a probe asserting it would fail every boot. What replaced
# it is stronger evidence, not weaker: the endpoint DOES answer, and the token it
# yields is worthless. `secretmanager.versions.access` on the GitHub App key must
# come back 403, and `monitoring.timeSeries.create` must come back 403. Those two
# are the whole of the #1958 reduction, expressed as something a host can check
# about ITSELF, from inside the identity it is worried about.
#
# It has to be checked at boot because it cannot be checked anywhere earlier.
# Terraform cannot see the IAM a caller's service account happens to hold, so a
# Windows pool pointed at an unreduced host identity plans clean, applies clean,
# and is only wrong once a pull request is running on it.
#
# This half is pure: the payload text, the shim definition, and the verdict.
# The harness that runs the payload as a slot user, and the Deny-Boot that acts
# on the verdict, live further down under "phase 6: the boot probe, the
# harness". They are separated because these functions are the ones holding the
# decisions, and these are the ones Pester can execute on ubuntu-latest.

$script:ProbeServiceName = 'ci-boot-probe'
$script:ProbeResultPath = 'C:\ci\boot-probe.json'

# The payload does NOT live under C:\ci\bin, for the reason phase 4's hooks do
# not either: that directory is locked to SYSTEM and Administrators with no slot
# ACE at all, and a payload the probing slot cannot read is a service that never
# starts. It gets its own directory, and that directory is slot-WRITABLE rather
# than slot-readable -- the shim writes `<id>.out.log` beside the config it was
# handed, and its append path catches IOException only, so a directory the
# service account cannot write is a service that fails in OnStart. The two files
# inside are re-locked to read-and-execute individually afterwards.
$script:ProbeRoot = 'C:\ci\boot-probe'
$script:ProbeScriptPath = 'C:\ci\boot-probe\ci-boot-probe.ps1'
$script:ProbeConfigPath = 'C:\ci\boot-probe\ci-boot-probe.xml'

# Bounded, like every wait in this file. A probe that never finishes must become
# a missing verdict -- which Get-ProbeFailure already treats as the loudest
# finding there is -- and not a boot that hangs at warm-host size until the
# register grace expires.
$script:ProbeWaitSeconds = 180
$script:ProbePollSeconds = 2

function Get-ProbeSiblingWorkspace {
    <#
      .SYNOPSIS
        The directory the probe tries, and must fail, to read. Pure.
      .DESCRIPTION
        The check being made is "this account cannot read a directory it was not
        given", and on a multi-slot host the honest subject is another SLOT's
        workspace. The Windows pool pins ci-slots to 1, so on almost every host
        there is no sibling slot at all -- and Get-ProbeFailure treats a sibling
        that was 'missing' as a FINDING, not a pass, because a path that is not
        there proves nothing about an ACL. Handing it a nonexistent sibling would
        therefore deny every boot in the pool.

        So a single-slot host is pointed at C:\ci\bin instead. That is not a
        weaker subject, it is a stronger one: it exists on every host this module
        boots, phase 1 locks it to SYSTEM and Administrators with no slot ACE,
        and it holds ci-beacon.ps1 -- the script the SCM re-executes as
        LocalSystem on every restart. A slot that can list it is a slot one step
        from owning SYSTEM here, which is the exact escalation the per-slot ACLs
        exist to refuse.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [Parameter(Mandatory = $true)][int] $SlotCount,
        [string] $SlotRoot = $script:SlotRoot,
        [string] $FallbackRoot = $script:BinRoot
    )
    if ($SlotCount -ge 2) {
        $sibling = 1
        if ($Index -eq 1) { $sibling = 2 }
        return (Get-SlotWorkspacePath -Index $sibling -Root $SlotRoot)
    }
    return $FallbackRoot
}

function Test-NegativeCapability {
    <#
      .SYNOPSIS
        Does this HTTP status prove the host token CANNOT do the thing? Pure.
      .DESCRIPTION
        403 and nothing else. The three near-misses are each a different kind of
        wrong and all three have to fail:

        200 is the finding. The identity was not reduced, the host token still
        reads the GitHub App key or still writes the demand metric, and every
        repository the App is installed on is reachable from a pull request.

        $null -- a DNS failure, a refused connection, a timeout -- is UNPROVED,
        not proved. Reading it as a pass is how a boundary decays into a comment:
        the one host where the check could not run is the one host nobody ever
        looks at again.

        401 is unproved too, and it is the subtle one. It means the request went
        out without a usable credential, so it says nothing at all about what the
        credential can do -- a probe whose token acquisition quietly failed
        returns 401 for every call and would otherwise report a perfect score.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()] $StatusCode)
    if ($null -eq $StatusCode) { return $false }
    if ("$StatusCode" -notmatch '^[0-9]+$') { return $false }
    return ([int] $StatusCode -eq 403)
}

function Test-PositiveCapability {
    <#
      .SYNOPSIS
        Does this HTTP status prove the host token CAN do the thing? Pure.
      .DESCRIPTION
        THE WITNESS THE REST OF PHASE 6 DOES NOT HAVE.

        Every other capability check here is negative, and a negative check
        cannot tell "correctly refused" from "there was nothing to refuse".
        Secret Manager answers 403 for a resource the caller may not read AND
        for one that does not exist, so a `ci-app-key-secret` that is misspelled,
        renamed or deleted scores exactly like a properly reduced identity. The
        same shape is true of the whole payload: an identity that can do nothing
        at all -- a token from a service account whose bindings were wiped, a
        proxy answering 403 to everything -- passes both negative checks
        perfectly. That is issue #157.

        So one assertion runs the other way. The host token is supposed to hold
        exactly one capability: `iam.serviceAccounts.getAccessToken` on the job
        service account, which is how the broker vends job credentials without
        the host holding any. If that answers 200, the token is live, the
        network reaches Google, and IAM is being evaluated on this call -- which
        is what makes the two 403s beside it mean refusal rather than absence.

        200 and nothing else, and the near-misses invert cleanly:

        403 is the finding. Either the grant is missing, in which case no job on
        this host can obtain the credentials it was designed to get, or the
        probe's whole picture is 403-shaped for a reason that has nothing to do
        with IAM -- and in the second case the negative checks above proved
        nothing.

        $null and 401 are UNPROVED for the same reasons Test-NegativeCapability
        rejects them, and they matter more here: this check exists to prove the
        measurement apparatus works, so accepting a failure to measure would
        make it the one assertion that certifies itself.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()] $StatusCode)
    if ($null -eq $StatusCode) { return $false }
    if ("$StatusCode" -notmatch '^[0-9]+$') { return $false }
    return ([int] $StatusCode -eq 200)
}

function Get-ProbeFailure {
    <#
      .SYNOPSIS
        Every reason this host must not register, from one probe verdict. Pure.
      .DESCRIPTION
        Returns an array of sentences; empty means the boot may continue. All of
        them, not the first: a host that is wrong in three ways should say so
        once, because the operator reading the serial console gets one look
        before the controller reclaims the instance.

        A missing or unparseable verdict is a failure with its own sentence,
        and that is the case this function exists to get right. The probe runs as
        an unprivileged account under a service that can fail to start; "no file"
        and "no findings" are the same absence of output, and reporting the second
        for the first is exactly the silent pass the whole phase exists to
        prevent.

        ExpectedIdentity is MANDATORY and has no default. Every other check here
        reads the same for LocalSystem as for a slot -- they all query the
        metadata server, which does not care who asks -- so without this one the
        phase would still pass if the repoint silently did not happen, and the
        boot log would say the slot boundary was proved by the account that owns
        the machine. A default would make the assertion skippable by omission,
        which is the shape of every bug this file is written against.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()] $Result,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $JobServiceAccount,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ExpectedIdentity
    )

    if ($null -eq $Result) {
        return , 'the probe produced no verdict at all -- nothing on this host has proved the slot boundary'
    }
    $fail = New-Object System.Collections.Generic.List[string]
    $get = {
        param($name)
        if ($Result.PSObject.Properties.Name -contains $name) { return $Result.$name }
        return $null
    }

    # WHO ANSWERED, before anything it answered is believed. The repoint to the
    # slot account is the one part of phase 6 with no hardware behind it, and a
    # probe that quietly stayed LocalSystem would otherwise pass every remaining
    # check: they all ask the metadata server, which answers the machine, not the
    # account.
    #
    # Compared on the LEAF only. WindowsIdentity.Name is `<machine>\<account>`
    # and the machine half is the instance name, which the harness would have to
    # re-derive to assert and which says nothing about the boundary. Case-
    # insensitive because Windows account names are, so a case difference here
    # would be a false denial and not a finding.
    $ran = [string] (& $get 'runningAs')
    $ranLeaf = $ran
    if ($ran.Contains('\')) { $ranLeaf = $ran.Substring($ran.LastIndexOf('\') + 1) }
    $wantLeaf = $ExpectedIdentity
    if ($wantLeaf.Contains('\')) { $wantLeaf = $wantLeaf.Substring($wantLeaf.LastIndexOf('\') + 1) }
    if ([string]::IsNullOrWhiteSpace($ran)) {
        $fail.Add(('the probe did not report which account it ran as, so nothing it reports is ' +
                'attributable to a slot -- every other check reads the same for LocalSystem'))
    } elseif ($ranLeaf -ine $wantLeaf) {
        $fail.Add(("the probe ran as '$ran' and not $ExpectedIdentity -- the service was never " +
                'repointed at the slot account, so the boundary a job runs behind is untested'))
    }

    # The premise of the two checks below it. A probe that never got a host token
    # cannot have proved anything about what a host token can do, and its two
    # perfect 401s would read as two passes.
    if ((& $get 'hostToken') -ne $true) {
        $fail.Add('the probe could not obtain a host token, so neither negative capability was proved')
    }
    if (-not (Test-NegativeCapability -StatusCode (& $get 'secretStatus'))) {
        $fail.Add(("secretmanager.versions.access answered '$(& $get 'secretStatus')' and not 403 -- " +
                'this host identity can still read the GitHub App key, so a pull request on it owns ' +
                'every repository the App is installed on'))
    }
    if (-not (Test-NegativeCapability -StatusCode (& $get 'metricStatus'))) {
        $fail.Add(("monitoring.timeSeries.create answered '$(& $get 'metricStatus')' and not 403 -- " +
                'this host identity can still write the demand series the autoscaler reads'))
    }

    # THE POSITIVE CONTROL, and it is deliberately read right after the two
    # negatives it qualifies. See Test-PositiveCapability: without it, an
    # identity that can do nothing at all -- or a probe whose calls never reached
    # Google -- answers 403 to both checks above and scores a perfect boundary.
    #
    # Only on a pool that HAS a job service account, and the two arms are not
    # symmetric. With one configured, 200 is required. With none, the payload
    # omits the call entirely, so a status arriving anyway means the payload on
    # disk does not match the configuration this boot script was handed -- the
    # same drift the broker arm below refuses, for the same reason.
    $impersonate = & $get 'impersonateStatus'
    $tries = & $get 'impersonateAttempts'
    $after = ''
    if ($null -ne $tries) { $after = " after $tries attempt(s)" }
    if ([string]::IsNullOrWhiteSpace($JobServiceAccount)) {
        if ($null -ne $impersonate) {
            $fail.Add(("the probe tried to mint a job token ('$impersonate') on a pool that configured " +
                    'no job service account, so the payload it ran is not the one this configuration builds'))
        }
    } elseif (-not (Test-PositiveCapability -StatusCode $impersonate)) {
        $fail.Add(("iamcredentials.generateAccessToken on $JobServiceAccount answered '$impersonate' and " +
                "not 200$after -- the host token cannot mint the job credentials the broker vends, and " +
                'until it can, the two 403s above are not evidence of a reduced identity: an identity ' +
                'that can do nothing at all answers 403 to everything'))
    }

    # Both halves, because a broker that silently fell back to the host identity
    # is the failure the broker exists to prevent, and it looks like a working
    # broker from every angle except this one.
    $email = [string] (& $get 'brokerEmail')
    if ([string]::IsNullOrWhiteSpace($JobServiceAccount)) {
        if (-not [string]::IsNullOrWhiteSpace($email)) {
            $fail.Add("a broker answered as '$email' on a pool that configured no job service account")
        }
    } elseif ($email -cne $JobServiceAccount) {
        # Case-sensitive on purpose. The claim being checked is "this is exactly
        # the identity the pool configured", and -ne would accept a near-miss.
        $fail.Add("the broker vends '$email', not $JobServiceAccount")
    }

    # Three outcomes, not two. Get-ChildItem throws identically on a denied path
    # and on a path that is not there, so folding them together would let a
    # sibling workspace that simply had not been created yet report as a proved
    # ACL boundary -- the same "absence read as a pass" this function refuses
    # for a missing verdict file.
    #
    # The exception type the payload recorded is APPENDED to both non-denied
    # findings, and it is the useful half of them. Which exception 5.1 actually
    # raises for an ACL-denied enumeration is unobserved on a real host, and the
    # two candidates land in different arms here -- so on the first host that
    # denies its boot over this, the finding itself says whether the ACL held
    # and the mapping is wrong, or the ACL did not hold. Without it the operator
    # is told the boundary is unproved and given nothing to prove it with.
    $sibling = [string] (& $get 'siblingStatus')
    $siblingType = [string] (& $get 'siblingErrorType')
    $sawType = 'no exception was recorded'
    if (-not [string]::IsNullOrWhiteSpace($siblingType)) { $sawType = "the exception was $siblingType" }
    if ($sibling -eq 'allowed') {
        $fail.Add('a slot could read another slot''s workspace -- the per-slot ACLs are not holding')
    } elseif ($sibling -eq 'missing') {
        $fail.Add('the sibling workspace was not there to read, so the per-slot ACLs were never tested ' +
            "-- $sawType, and if that names an access denial then 5.1 reported the denial " +
            'item-not-found-shaped and this mapping, not the ACL, is what is wrong')
    } elseif ($sibling -ne 'denied') {
        $fail.Add("the sibling read neither succeeded nor was denied ('$sibling') -- the per-slot " +
            "ACLs are unproved, and $sawType")
    }
    if ((& $get 'cacheWritable') -ne $true) {
        $fail.Add('the warm cache is not writable by a slot, so every job on this host repopulates it')
    }
    if ((& $get 'dnsResolved') -ne $true) {
        $fail.Add('name resolution failed from a slot context, so no agent on this host could reach GitHub')
    }
    return $fail.ToArray()
}

function Test-ProbeLiteral {
    <#
      .SYNOPSIS
        Whether a value may be interpolated into the probe payload. Pure.
      .DESCRIPTION
        Get-ProbeScript builds PowerShell source text, so every value it
        interpolates is code. The secret name and the broker endpoint both come
        from instance metadata, which section 3A of the ADR says outright is
        readable AND writable by anything with the machine's identity -- and a
        single apostrophe closes the literal it lands in and appends statements
        to a payload that runs holding a live, unreduced host token. That is a
        larger capability than the one the probe exists to disprove.

        Allow-list, and throw rather than sanitize. A stripped value would still
        build a payload, and a payload that quietly measured the wrong secret is
        worse than a boot that stops with the reason on the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $Value,
        [Parameter(Mandatory = $true)][ValidateSet('name', 'endpoint', 'path', 'url', 'email')][string] $Kind
    )
    if ([string]::IsNullOrEmpty($Value)) { return $true }
    switch ($Kind) {
        'name' { return ($Value -match '^[A-Za-z0-9_-]+$') }
        'endpoint' { return ($Value -match '^[A-Za-z0-9._-]+:[0-9]+$') }
        # A service-account email, and deliberately narrower than RFC 5322: it is
        # about to be spliced into a URL inside a double-quoted PowerShell string
        # in a payload holding a live host token, so the characters that matter
        # are the ones that end a literal or start a subexpression. Nothing here
        # admits a quote, a backtick, a `$` or a slash.
        'email' { return ($Value -match '^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$') }
        'url' { return ($Value -match '^https?://[A-Za-z0-9._-]+(:[0-9]+)?(/[A-Za-z0-9._-]+)*$') }
        default { return ($Value -match '^[A-Za-z]:\\[A-Za-z0-9 \\._-]*$') }
    }
}

function Get-ProbeScript {
    <#
      .SYNOPSIS
        The payload the probe runs AS A SLOT USER, as PowerShell text. Pure.
      .DESCRIPTION
        It records; it does not decide. Every check writes a value into one JSON
        document and nothing in here calls Deny-Boot, because the payload runs
        unprivileged in a service the boot script does not share a process with:
        a verdict it reached could not be trusted, and a verdict it failed to
        write must not be mistaken for a clean one. Get-ProbeFailure decides,
        back in the boot script, where "no file" is a finding.

        Two details are load-bearing and neither is obvious.

        The payload asks the REAL metadata server, 169.254.169.254, and never the
        broker, for the token it then tries to spend. That is the point: the
        question is what a job can reach behind this script's back, and pointing
        it at the closed endpoint the runner service's environment sets would
        measure the environment block instead of the identity.

        Every call is wrapped and every failure lands in the document as $null
        rather than as an exception. A payload that throws writes nothing, which
        Get-ProbeFailure reports as "no verdict at all" -- correct, but it names
        the wrong problem, and the operator loses the five checks that did run.

        CacheRoot is the slot's OWN workspace root. There is no host-wide warm
        cache directory on this image -- the caches the pool exists to keep warm
        live under each slot's profile -- so "the warm cache is writable" is
        proved where the cache actually is, by the account that has to write it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $SecretName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $JobServiceAccount,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $BrokerEndpoint,
        [Parameter(Mandatory = $true)][string] $SiblingWorkspace,
        [Parameter(Mandatory = $true)][string] $CacheRoot,
        [string] $ResultPath = $script:ProbeResultPath,
        [string] $MetadataRoot = $script:MetadataRoot,
        [int] $TimeoutSeconds = $script:HttpTimeoutSeconds
    )

    # Every one of these becomes code. See Test-ProbeLiteral for why a metadata
    # value reaching this point unchecked is worse than the finding it looks for.
    foreach ($pair in @(
            @{ n = 'SecretName'; v = $SecretName; k = 'name' },
            @{ n = 'JobServiceAccount'; v = $JobServiceAccount; k = 'email' },
            @{ n = 'BrokerEndpoint'; v = $BrokerEndpoint; k = 'endpoint' },
            @{ n = 'SiblingWorkspace'; v = $SiblingWorkspace; k = 'path' },
            @{ n = 'CacheRoot'; v = $CacheRoot; k = 'path' },
            @{ n = 'ResultPath'; v = $ResultPath; k = 'path' },
            @{ n = 'MetadataRoot'; v = $MetadataRoot; k = 'url' })) {
        if (-not (Test-ProbeLiteral -Value $pair.v -Kind $pair.k)) {
            throw ("probe $($pair.n) '$($pair.v)' is not a bare $($pair.k), so it would be " +
                'interpolated as code into a payload that holds a host token')
        }
    }

    # The positive control, omitted on the same terms as the broker read below
    # and for the same reason: a pool with no job service account has no
    # impersonation to prove, and Get-ProbeFailure treats a status arriving from
    # such a pool as payload-versus-configuration drift.
    #
    # RETRIED, unlike every other check in the payload. This is the one
    # assertion whose subject is an IAM binding rather than a local ACL or a
    # refusal, and a binding created seconds ago by the same apply that created
    # the pool is not always in force yet. Every other check answers the same on
    # attempt one and attempt three; this one can answer 403 on a host that is
    # about to be correct. Without the retry, the first boot after a fresh apply
    # denies itself, and `keep:at-floor` then pins that host at min_hosts.
    #
    # Bounded at three because a boot cannot wait on IAM indefinitely, and the
    # attempt count is carried out so the finding can say whether the grant was
    # missing for twenty seconds or was never there.
    $impersonateBlock = ''
    if (-not [string]::IsNullOrWhiteSpace($JobServiceAccount)) {
        $impersonateBlock = @"
if (`$tok) {
    for (`$i = 1; `$i -le 3; `$i++) {
        `$r.impersonateAttempts = `$i
        # Get-Status DISCARDS the body, which here is a live access token for the
        # job service account. The question is whether the call is permitted, and
        # a probe that kept the answer would be writing a credential into a
        # verdict file for the sake of a status code it already has.
        `$r.impersonateStatus = Get-Status ``
            -Uri 'https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$JobServiceAccount`:generateAccessToken' ``
            -Method 'POST' -Body '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}'
        if (`$r.impersonateStatus -eq 200) { break }
        if (`$i -lt 3) { Start-Sleep -Seconds 10 }
    }
}
"@
    }

    # OMITTED, not disabled. A runtime `if ('')` around the broker read would
    # leave the endpoint and the path in the payload text, where the only thing
    # that stops them being used is a condition somebody could later "simplify".
    # A no-broker pool's probe should not contain a broker read at all.
    $brokerBlock = ''
    if (-not [string]::IsNullOrWhiteSpace($BrokerEndpoint)) {
        $brokerBlock = @"
try {
    `$r.brokerEmail = [string] (Invoke-RestMethod ``
            -Uri 'http://$BrokerEndpoint/computeMetadata/v1/instance/service-accounts/default/email' ``
            -Headers `$md -TimeoutSec $TimeoutSeconds)
} catch { `$null = `$_ }
"@
    }

    return @"
`$ErrorActionPreference = 'Stop'
`$md = @{ 'Metadata-Flavor' = 'Google' }
`$r = [ordered] @{
    runningAs = ''; hostToken = `$false; secretStatus = `$null; metricStatus = `$null
    impersonateStatus = `$null; impersonateAttempts = `$null
    brokerEmail = ''; siblingStatus = 'unrun'; siblingErrorType = ''
    cacheWritable = `$false; dnsResolved = `$false
}

# WHO IS ANSWERING. Every other field in this document queries the metadata
# server and reads identically for every local account on the host, so none of
# them say anything about the account that ran this. The process token does, and
# it is the one claim the slot-account repoint can be checked against.
#
# WindowsIdentity and not `$env:USERNAME: the environment block of a service is
# data the SCM copies in and this script's own Write-ServiceEnvironment rewrites
# elsewhere, so it can say one thing while the process runs as another --
# precisely the divergence being tested for. GetCurrent() reads the token the
# access checks are actually made against. It is in every .NET Framework this
# fleet boots on.
try { `$r.runningAs = [string] ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) } catch { `$null = `$_ }

# The real metadata server, deliberately. See Get-ProbeScript's description.
`$tok = ''
try {
    `$t = Invoke-RestMethod -Uri '$MetadataRoot/instance/service-accounts/default/token' ``
        -Headers `$md -TimeoutSec $TimeoutSeconds
    if (`$t -and `$t.access_token) { `$tok = [string] `$t.access_token; `$r.hostToken = `$true }
} catch { `$null = `$_ }

`$project = ''
try {
    `$project = [string] (Invoke-RestMethod -Uri '$MetadataRoot/project/project-id' ``
            -Headers `$md -TimeoutSec $TimeoutSeconds)
} catch { `$null = `$_ }

# A status, never a body. Both calls are EXPECTED to be refused, so the
# interesting value is the refusal code and the payload must not be read.
function Get-Status {
    param(`$Uri, `$Method, `$Body)
    try {
        `$null = Invoke-WebRequest -Uri `$Uri -Method `$Method -Body `$Body ``
            -ContentType 'application/json' -Headers @{ Authorization = "Bearer `$tok" } ``
            -TimeoutSec $TimeoutSeconds -UseBasicParsing
        return 200
    } catch {
        if (`$_.Exception.Response) { return [int] `$_.Exception.Response.StatusCode }
        return `$null
    }
}

if (`$tok -and `$project -and '$SecretName') {
    `$r.secretStatus = Get-Status ``
        -Uri "https://secretmanager.googleapis.com/v1/projects/`$project/secrets/$SecretName/versions/latest:access" ``
        -Method 'GET' -Body `$null
    # An empty series list. IAM is evaluated before the request body is, so a
    # host that may not write gets 403 and a host that may gets 400 -- and 400
    # is not 403, which is the finding either way.
    `$r.metricStatus = Get-Status ``
        -Uri "https://monitoring.googleapis.com/v3/projects/`$project/timeSeries" ``
        -Method 'POST' -Body '{"timeSeries":[]}'
}

$impersonateBlock

$brokerBlock

# Denial is the pass, and 'missing' is NOT denial: Get-ChildItem throws the same
# way for a path this account may not read and a path that is not there, so the
# exception type is the only thing that separates a proved ACL from an untested
# one. Get-ProbeFailure treats every value but 'denied' as a finding.
#
# THE TYPE NAME IS RECORDED, NOT ONLY THE VERDICT IT MAPPED TO. Which exception
# 5.1 raises for an ACL-denied enumeration is NOT something this branch has
# observed on a real host: it is documented as UnauthorizedAccessException and
# it is also reported as surfacing item-not-found-shaped, and those two map to
# opposite conclusions here -- 'denied' passes, 'missing' denies the boot on
# every host in the pool. Guessing produces a fleet that will not boot and a
# verdict file that does not say why. So the concrete type is carried out
# alongside the status and Get-ProbeFailure prints it, and the first real boot
# settles the question instead of leaving the next reader to re-derive it.
try {
    `$null = Get-ChildItem -LiteralPath '$SiblingWorkspace' -Force -ErrorAction Stop
    `$r.siblingStatus = 'allowed'
} catch {
    `$r.siblingErrorType = [string] `$_.Exception.GetType().FullName
    if (`$_.Exception -is [System.UnauthorizedAccessException]) {
        `$r.siblingStatus = 'denied'
    } elseif (`$_.Exception -is [System.Management.Automation.ItemNotFoundException]) {
        `$r.siblingStatus = 'missing'
    } else {
        `$r.siblingStatus = 'error'
    }
}

try {
    `$probe = Join-Path '$CacheRoot' ('probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
    Set-Content -LiteralPath `$probe -Value 'probe' -ErrorAction Stop
    Remove-Item -LiteralPath `$probe -Force -ErrorAction SilentlyContinue
    `$r.cacheWritable = `$true
} catch { `$null = `$_ }

try {
    `$r.dnsResolved = [bool] ([System.Net.Dns]::GetHostEntry('github.com').AddressList.Count)
} catch { `$null = `$_ }

`$r | ConvertTo-Json -Compress | Set-Content -LiteralPath '$ResultPath' -Encoding ASCII
"@
}

function Get-ProbeServiceConfig {
    <#
      .SYNOPSIS
        The shim's service definition for the boot probe, as XML text. Pure.
      .DESCRIPTION
        Manual and non-restarting, and both differ from every other service this
        file installs for the same reason: the probe is a one-shot measurement,
        not a daemon. `Automatic` would re-run it on every reboot of a host whose
        boot script is not running, writing a verdict nobody reads; `onfailure
        restart` would turn a payload that cannot start into an infinite loop
        instead of a missing file, and a missing file is precisely the signal
        Get-ProbeFailure needs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [string] $ServiceName = $script:ProbeServiceName
    )
    $esc = { param($v) [System.Security.SecurityElement]::Escape([string] $v) }
    $svc = & $esc $ServiceName
    $shimArgs = & $esc "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    return @"
<service>
  <id>$svc</id>
  <name>$svc</name>
  <description>Proves this CI host's slot boundary from a slot's own context, once.</description>
  <executable>powershell.exe</executable>
  <arguments>$shimArgs</arguments>
  <startmode>Manual</startmode>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>2</keepFiles>
  </log>
</service>
"@
}

# --- phase 0 -----------------------------------------------------------------

function Get-MetadataValue {
    <#
      .SYNOPSIS
        Read one metadata value. Empty string when absent.
      .DESCRIPTION
        Every STATIC attribute is read in phase 0, once. The original reason was
        the phase-2 fence, which would have taken this script's own access to
        169.254.169.254:80 away; section 3A deleted the fence, so the endpoint
        stays reachable all boot long. The constraint survives on a different
        footing: one read site is one place to look when a boot fails on a missing
        attribute, and a later phase that reads its own metadata is a phase whose
        inputs no test can construct.

        There is exactly ONE other caller, Wait-RegistrationToken, and it is not
        an exception to that rule -- it is the reason the rule says STATIC. The
        registration token is written by the CONTROLLER, after this host has
        started booting, and deleted again once the host registers; it is the one
        attribute whose value at phase 0 says nothing about its value later. It is
        still read once, above the slot loop, for the reason at the top of this
        file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        return [string](Invoke-RestMethod `
                -Uri "$script:MetadataRoot/$Path" `
                -Headers @{ 'Metadata-Flavor' = 'Google' } `
                -TimeoutSec $script:HttpTimeoutSeconds)
    } catch {
        # Fail CLOSED on anything that is not a 404. An earlier version of this
        # function swallowed every exception into '', which made one flaky read
        # indistinguishable from "the attribute is not set" -- and the two
        # attributes where that matters are the two where '' is a decision, not
        # a default: an unread ci-job-service-account silently converts a broker
        # pool into a no-broker pool, and an unread ci-image-min-version drops
        # the image floor to 1 and lets a host boot from an image with no shim.
        # A transport error choosing which identity a pool runs as is not an
        # error path anybody would have signed off on. Losing the host is the
        # cheaper outcome, every time.
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = $_.Exception.Response.StatusCode
        }
        if (Test-MetadataAbsence -StatusCode $status) { return '' }
        Deny-Boot ("could not read metadata '$Path' ($($_.Exception.Message)) -- refusing to " +
            'treat an unreadable attribute as an unset one')
    }
}

function Install-BeaconService {
    <#
      .SYNOPSIS
        Materialise the beacon script and run it under the image's shim.
      .DESCRIPTION
        The script arrives as instance metadata rather than living in the image,
        so a beacon fix ships by rolling instances instead of by rebuilding and
        re-rolling an image. The shim does NOT arrive that way: an executable
        delivered through a channel any process on the VM can write is a
        different kind of thing entirely, and it stays in the image.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScriptText,
        [int] $IntervalSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $script:ServiceShim)) {
        Deny-Boot ("the service shim $script:ServiceShim is missing -- this image predates the " +
            'beacon and cannot run one, and a host that cannot say whether it is busy can ' +
            'never be safely deleted')
    }

    # UTF-8 WITH a BOM, written through .NET rather than Set-Content. The two
    # PowerShells disagree: `-Encoding UTF8` means with-BOM on Windows
    # PowerShell 5.1 and without-BOM on 7. A BOM-less file read back by 5.1 --
    # which is what runs the service -- is decoded as ANSI, so the first
    # non-ASCII byte anyone ever adds to the beacon becomes a parse error on a
    # host nobody is watching. Naming the encoding removes the disagreement.
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $scriptPath = Join-Path $script:BinRoot 'ci-beacon.ps1'
    [System.IO.File]::WriteAllText($scriptPath, $ScriptText, $utf8Bom)

    $configPath = Join-Path $script:BinRoot 'ci-beacon.xml'
    [System.IO.File]::WriteAllText($configPath,
        (Get-BeaconServiceConfig -ScriptPath $scriptPath -IntervalSeconds $IntervalSeconds),
        $utf8Bom)

    # Install then start, each checked. `& shim install` is the one call here
    # whose failure is silent by default: it writes to stderr and returns
    # non-zero, and nothing in PowerShell turns that into an exception.
    #
    # The preference is dropped around it deliberately. Under
    # $ErrorActionPreference = 'Stop' -- which the entry point sets -- `2>&1` on
    # a NATIVE command turns each stderr line into a terminating
    # NativeCommandError, so a shim that merely warns would abort the boot here
    # and never reach the exit-code check three lines down. The exit code is the
    # signal; stderr is commentary.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $shimOutput = & $script:ServiceShim 'install' $configPath 2>&1
    $shimExit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($shimOutput)) { Write-BootLog "shim: $line" }
    if ($shimExit -ne 0) {
        Deny-Boot "the service shim refused to install the beacon (exit $shimExit)"
    }

    Start-Service -Name $script:BeaconServiceName -ErrorAction Stop
    $svc = Get-Service -Name $script:BeaconServiceName -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Deny-Boot "the beacon service is '$($svc.Status)', not Running"
    }
    Write-BootLog "phase 0: beacon service running, interval ${IntervalSeconds}s"
    return $scriptPath
}

function Invoke-Phase0Preflight {
    <#
      .SYNOPSIS
        Read the metadata, assert the OS and the image, start the beacon.
      .DESCRIPTION
        A failed first beacon write is FATAL. A host that cannot say whether it
        is busy is a host that can never be safely deleted -- `beacon_decision()`
        correctly returns keep, forever -- and it is far cheaper to lose it to
        the register-grace drain now than to keep it, billing and invisible,
        later.
    #>
    [CmdletBinding()]
    param()

    Write-BootLog 'phase 0: preflight'
    New-Item -ItemType Directory -Force -Path $script:CiRoot, $script:BinRoot, $script:SlotRoot | Out-Null

    $cfg = [ordered] @{
        Owner          = Get-MetadataValue 'instance/attributes/ci-github-owner'
        Repo           = Get-MetadataValue 'instance/attributes/ci-github-repo'
        HostOs         = Get-MetadataValue 'instance/attributes/ci-host-os'
        Slots          = Get-MetadataValue 'instance/attributes/ci-slots'
        Pool           = Get-MetadataValue 'instance/attributes/ci-pool'
        ImageFloor     = Get-MetadataValue 'instance/attributes/ci-image-min-version'
        BeaconScript   = Get-MetadataValue 'instance/attributes/ci-beacon-script'
        BeaconInterval = Get-MetadataValue 'instance/attributes/ci-beacon-interval'
        InstanceName   = Get-MetadataValue 'instance/name'
        Labels         = Get-MetadataValue 'instance/attributes/ci-runner-labels'
        # Derived below from InstanceName, once it is known to be non-empty.
        HostLabel      = ''
        RunnerGroup    = Get-MetadataValue 'instance/attributes/ci-runner-group'
        JobSa          = Get-MetadataValue 'instance/attributes/ci-job-service-account'
        BrokerPort     = Get-MetadataValue 'instance/attributes/ci-job-broker-port'
        BrokerSource   = Get-MetadataValue 'instance/attributes/ci-job-broker-py'
        # Phase 6's subject, not phase 0's. The probe asks whether THIS host's
        # identity can still read the GitHub App key, so it needs the key's
        # name -- and it is read here with everything else static rather than
        # from inside the phase, for the reason Get-MetadataValue gives.
        AppKeySecret   = Get-MetadataValue 'instance/attributes/ci-app-key-secret'
        # Phase 7's telemetry, read here with everything else static. Absent on a
        # host booted from a template cut before the key existed, which the
        # publisher treats as "this pool does not publish" rather than as an
        # error -- the same fallback every cache key gets.
        MetricPrefix   = Get-MetadataValue 'instance/attributes/ci-metric-prefix'
        # The project and the zone are read from the machine rather than passed
        # in metadata that already knows them: a second copy of the project id is
        # a second thing that can disagree with the host it is running on.
        ProjectId      = Get-MetadataValue 'project/project-id'
        Zone           = Get-MetadataValue 'instance/zone'
    }

    if ([string]::IsNullOrWhiteSpace($cfg.Owner) -or [string]::IsNullOrWhiteSpace($cfg.Repo)) {
        Deny-Boot 'missing ci-github-owner/ci-github-repo metadata'
    }

    # An empty label set is the silent version of a dead pool. The controller
    # exits outright on it, because demand would match nothing and the pool would
    # sit at zero hosts while jobs queue; a HOST with no labels is the other half
    # of the same fault -- it registers, GitHub sends it nothing, and the boot log
    # reads as a success. An empty instance name is the same shape one layer down:
    # the agent registers as `-s1`, which orphan_decision() cannot parse back to
    # any instance, so the registration outlives the host forever.
    if ([string]::IsNullOrWhiteSpace($cfg.Labels)) {
        Deny-Boot ('ci-runner-labels metadata is missing or empty -- agents registered without ' +
            'labels are never sent a job, and the host would look perfectly healthy doing nothing')
    }
    if ([string]::IsNullOrWhiteSpace($cfg.InstanceName)) {
        Deny-Boot ('the metadata server did not name this instance -- an agent registered without ' +
            'it cannot be traced back to a host and would never be reaped')
    }

    # Every agent on this host also answers to `host-<instance-name>`, which is
    # what lets a workflow run keep its later jobs on the host its first job
    # landed on (docs/adr-pr-host-affinity.md). GitHub routes a job to any runner
    # whose label set is a SUPERSET of `runs-on`, so this costs nothing to a
    # workflow that does not name it. Appended after both checks above, because
    # it is only well-defined once the instance has a name and the pool has
    # labels -- and the module cannot pass it in metadata, since a MIG assigns
    # the instance name at creation.
    $cfg.HostLabel = "host-$($cfg.InstanceName)"
    $cfg.Labels = "$($cfg.Labels),$($cfg.HostLabel)"

    # Here rather than in phase 7, because these are the attributes phase 0 has
    # just read and phase 7 must not read again. No network: it only records who
    # this host is for the hydrate's flush.
    Initialize-CacheTelemetry -Config $cfg

    # The OS marker is asserted, not assumed. Terraform decides which metadata
    # key carries which boot script; a mis-wired pool would otherwise deliver
    # this script to a Linux template and fail in some unrelated place minutes
    # later. Refusing here names the actual mistake.
    if ($cfg.HostOs -ne 'windows') {
        Deny-Boot "ci-host-os is '$($cfg.HostOs)', not 'windows' -- this host was given the wrong boot script"
    }

    $floor = 1
    if ($cfg.ImageFloor -match '^[0-9]+$') { $floor = [int] $cfg.ImageFloor }
    $marker = ''
    if (Test-Path -LiteralPath $script:ImageMarker) {
        $marker = Get-Content -Raw -LiteralPath $script:ImageMarker
    }
    if (-not (Test-ImageVersion -Marker $marker -Floor $floor)) {
        Deny-Boot ("golden image version '$($marker.Trim())' is below the required $floor -- " +
            'this host was booted from the wrong image, and booting a bare one here would ' +
            'reintroduce the per-job install cost this pool removes')
    }
    Write-BootLog "phase 0: image version $($marker.Trim()) >= $floor"

    if ([string]::IsNullOrWhiteSpace($cfg.BeaconScript)) {
        Deny-Boot ('ci-beacon-script metadata is empty -- this host would have no liveness ' +
            'beacon, and a host that cannot say whether it is busy can never be safely deleted')
    }

    if (-not [System.Diagnostics.EventLog]::SourceExists($script:BeaconServiceName)) {
        New-EventLog -LogName Application -Source $script:BeaconServiceName -ErrorAction SilentlyContinue
    }

    $interval = 30
    if ($cfg.BeaconInterval -match '^[0-9]+$') { $interval = [int] $cfg.BeaconInterval }
    $beaconPath = Install-BeaconService -ScriptText $cfg.BeaconScript -IntervalSeconds $interval

    # `ci/boot` is what makes the ABSENT case decidable on the controller: a host
    # past its register grace with no beacon at all and no agent in GitHub's list
    # never ran this script, so no worker can exist on it. Writing it here, from
    # this process, is also the first proof that the guest-attributes path works
    # at all on this instance -- and it is deliberately NOT delegated to the
    # service, whose own first write happens on its own schedule and whose
    # failure this process would never see.
    . $beaconPath
    if (-not (Write-GuestAttribute -Key 'boot' -Value (Get-BeaconTimestamp) -TimeoutSeconds $script:HttpTimeoutSeconds)) {
        Deny-Boot ('the first guest-attribute write failed -- this host could never be safely ' +
            'deleted, so it refuses to serve')
    }
    Write-BootLog 'phase 0: ci/boot published'

    return $cfg
}

# --- phase 1: slot accounts, ACLs, TEMP --------------------------------------
#
# THE VERBS IN THIS SECTION ARE CHOSEN AROUND THE ANALYZER, ONCE, HERE
#
# PSUseShouldProcessForStateChangingFunctions is Warning severity and
# powershell-gate.sh fails on it, so a `Set-`, `New-` or `Remove-` function here
# would have to carry -WhatIf plumbing. A boot script that half-honours -WhatIf
# is a worse object than one with slightly unusual verbs, so the state-changing
# functions use approved verbs outside that rule's list -- Protect-, Grant-,
# Initialize- -- and say so rather than leaving the next reader to wonder.

function Get-AclInheritanceFlag {
    <#
      .SYNOPSIS
        The InheritanceFlags an ACE may carry on this path. Pure.
      .DESCRIPTION
        A DIRECTORY ACE is inheritable: ContainerInherit + ObjectInherit is what
        makes the lock apply to everything created underneath it later.

        A FILE ACE may carry NO flags at all, and this is not a style preference.
        FileSecurity.AddAccessRule REJECTS a rule with inheritance flags on a file:

            Exception calling "AddAccessRule" with "1" argument(s):
            "No flags can be set. Parameter name: inheritanceFlags"

        That throw lands under the entry point's $ErrorActionPreference = 'Stop',
        so the wrong constant here is not a cosmetically loose ACL -- it is a host
        that never finishes booting. Separated out and returned rather than set,
        so a test can assert both answers without an NTFS volume.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool] $IsContainer)

    if ($IsContainer) {
        return [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    return [System.Security.AccessControl.InheritanceFlags]::None
}

function Protect-CiDirectory {
    <#
      .SYNOPSIS
        Lock one directory or file to SYSTEM, Administrators and (optionally) one slot.
      .DESCRIPTION
        Windows creates C:\Users\ci-s<i> at first logon with an ACL of the user,
        SYSTEM and Administrators -- the default is already close to what we want.
        That is not a reason to skip this; it is the reason it is cheap. "Windows
        does the right thing by default" is a claim about an IMAGE, and the image
        changes.

        Inheritance is DISABLED and not copied. Copying it would preserve exactly
        the Users / Authenticated Users entries this exists to remove, and would
        leave a directory that looks locked in the UI and is not -- the same class
        of mistake as a firewall rule that installs and filters nothing.

        Omitting -SlotUser locks the directory to SYSTEM and Administrators only,
        which is how C:\ci and C:\ci\bin are treated: the beacon script lives
        there, the SCM re-executes it as LocalSystem on every restart and reboot,
        and a slot account able to write it would own SYSTEM on this host without
        ever touching the job boundary.

        -ReadOnlyUser is the job-hook shape: every slot must be able to RUN the
        file and none may rewrite it. One hook is executed by every slot on the
        host, so a slot that could write it would be running code in every other
        slot's identity -- this is the Windows spelling of `chown root:root` plus
        `0755`, and it is not optional.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $SlotUser,
        [string[]] $ReadOnlyUser = @()
    )

    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }

    $inherit = Get-AclInheritanceFlag -IsContainer ((Get-Item -LiteralPath $Path).PSIsContainer)
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    # SIDs for the builtins, because their NAMES are localised and this module has
    # no say in which image a customer builds from. 'BUILTIN\Administrators' is
    # 'BUILTIN\Administratoren' on a German image and Get-Acl would reject it.
    $grants = @(
        @{ Id = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'); Rights = 'FullControl' },
        @{ Id = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'); Rights = 'FullControl' }
    )
    if ($SlotUser) {
        $grants += @{ Id = [System.Security.Principal.NTAccount]::new($SlotUser); Rights = 'Modify' }
    }
    foreach ($reader in @($ReadOnlyUser)) {
        $grants += @{ Id = [System.Security.Principal.NTAccount]::new($reader); Rights = 'ReadAndExecute' }
    }

    foreach ($grant in $grants) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $grant.Id, $grant.Rights, $inherit, $none, $allow))) | Out-Null
    }
    Set-Acl -Path $Path -AclObject $acl
}

function Edit-InfPrivilege {
    <#
      .SYNOPSIS
        Set one privilege's account list in a security-policy INF. Pure.
      .DESCRIPTION
        There is no in-box cmdlet for user rights assignment, so the mechanism is
        secedit: export the local policy to an INF, rewrite the [Privilege Rights]
        line, import it back. This function is the rewrite, separated out so
        Pester can assert it on ubuntu-latest -- the alternative is discovering a
        malformed INF on a booting host, where secedit's report of it is a
        non-zero exit code and a log file nobody reads.

        Returns new text; the input string is untouched. Four semantics matter and
        each is asserted by a test:

          * an ABSENT privilege line is ADDED, not silently skipped. A fresh image
            has no SeDenyNetworkLogonRight line at all, and skipping is how a deny
            the code claims to apply ends up not applied;
          * an existing line is REPLACED, not appended to. Appending would leave
            the previous membership in place, which for a deny right reads as
            working and for SeServiceLogonRight quietly widens it;
          * the [Privilege Rights] section is created when the export has none;
          * accounts are written as-is. The caller passes SIDs, because secedit
            resolves names against a locale-dependent account database and this
            script must behave the same on a non-English image.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $InfText,
        [Parameter(Mandatory = $true)][string] $Privilege,
        [Parameter(Mandatory = $true)][string[]] $Accounts
    )

    $line = "$Privilege = " + ($Accounts -join ',')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($InfText -split "`r?`n"))

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Privilege))\s*=") {
            $lines[$i] = $line
            return ($lines -join "`r`n")
        }
    }

    $section = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[Privilege Rights\]\s*$') { $section = $i; break }
    }
    if ($section -lt 0) {
        $lines.Add('[Privilege Rights]')
        $lines.Add($line)
    } else {
        $lines.Insert($section + 1, $line)
    }
    return ($lines -join "`r`n")
}

function Grant-SlotLogonRight {
    <#
      .SYNOPSIS
        Grant the slots service logon; deny them every other way in.
      .DESCRIPTION
        SeServiceLogonRight is granted EXPLICITLY here, before config.cmd is ever
        called. GitHub's --runasservice may grant it as a side effect of its own
        installer; that is not established from primary documentation, and a
        safety property that depends on somebody else's installer is not a
        property.

        The three denies are what make the service password harmless. It has to
        exist -- a Windows service logon takes a credential -- so the containment
        is that the credential buys nothing else: no console session, no session
        over the network, no RDP. Deny entries beat allow entries in Windows, so
        this holds even if a later change adds one of these accounts to a group
        that has the right.

        Applied in ONE secedit import, not four. Each import is a full policy
        write, and a host that took four of them could be interrupted between two
        and come up with the grant applied and the denies not -- the exact state
        this exists to prevent, reached by the code meant to prevent it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]] $SlotUsers)

    # SIDs, not names, for the reason given in Edit-InfPrivilege.
    $sids = @($SlotUsers | ForEach-Object {
            '*' + ([System.Security.Principal.NTAccount]::new($_)).Translate(
                [System.Security.Principal.SecurityIdentifier]).Value
        })

    # C:\ci, not $env:TEMP. Under SYSTEM that resolves to C:\Windows\Temp, where
    # unprivileged principals can create files -- and this is the file that
    # decides who holds SeServiceLogonRight and the three deny rights. C:\ci is
    # already SYSTEM-and-Administrators-only by the time this runs.
    $work = Join-Path $script:CiRoot ('ci-secpol-' + [guid]::NewGuid().ToString('N'))
    $exported = "$work.inf"
    $db = "$work.sdb"
    try {
        # The preference is dropped around both native calls for the reason given
        # in Install-BeaconService: under Stop, `2>&1` on a native command turns
        # each stderr line into a terminating NativeCommandError, and secedit
        # writes progress chatter there even when it succeeds.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $exportOutput = & secedit.exe /export /cfg $exported /areas USER_RIGHTS 2>&1
        $exportExit = $LASTEXITCODE
        $ErrorActionPreference = $previous
        foreach ($line in @($exportOutput)) { Write-BootLog "secedit: $line" }
        if ($exportExit -ne 0 -or -not (Test-Path -LiteralPath $exported)) {
            Deny-Boot ("secedit could not export the local security policy (exit $exportExit), " +
                'so slot logon rights cannot be proven applied')
        }

        $inf = Get-Content -Raw -LiteralPath $exported
        # The grant is MERGED with whatever already holds it -- taking
        # SeServiceLogonRight away from the image's own services would stop them.
        # The denies are set to exactly the slots: a deny list is this script's to
        # own, and anything else in it came from an image change nobody reviewed.
        $existingGrant = @()
        if ($inf -match '(?m)^\s*SeServiceLogonRight\s*=\s*(.+)$') {
            $existingGrant = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $grant = @($existingGrant + $sids | Select-Object -Unique)

        $inf = Edit-InfPrivilege -InfText $inf -Privilege 'SeServiceLogonRight' -Accounts $grant
        foreach ($deny in @('SeDenyInteractiveLogonRight',
                'SeDenyNetworkLogonRight',
                'SeDenyRemoteInteractiveLogonRight')) {
            $inf = Edit-InfPrivilege -InfText $inf -Privilege $deny -Accounts $sids
        }

        # UTF-16LE with a BOM, named through .NET rather than through -Encoding.
        # secedit REQUIRES Unicode and reports a file it cannot parse as a generic
        # non-zero exit; `Set-Content -Encoding Unicode` happens to agree today,
        # but the same parameter already means two different things for UTF8 on
        # 5.1 and 7, which is exactly how this class of bug arrives.
        [System.IO.File]::WriteAllText($exported, $inf, [System.Text.UnicodeEncoding]::new($false, $true))

        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $configOutput = & secedit.exe /configure /db $db /cfg $exported /areas USER_RIGHTS 2>&1
        $configExit = $LASTEXITCODE
        $ErrorActionPreference = $previous
        foreach ($line in @($configOutput)) { Write-BootLog "secedit: $line" }
        if ($configExit -ne 0) {
            Deny-Boot ("secedit could not apply slot logon rights (exit $configExit); the slot " +
                'service password would buy an interactive session')
        }
        Write-BootLog "phase 1: service logon granted, interactive/network/RDP denied for $($SlotUsers -join ', ')"
    } finally {
        Remove-Item -LiteralPath $exported, $db -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-SlotAccount {
    <#
      .SYNOPSIS
        Create (or adopt) one slot's local account and its directories.
      .DESCRIPTION
        The account is NOT in Administrators and NOT in Remote Desktop Users, and
        membership is removed rather than merely not granted -- an image that
        ships a `ci-s1` in Administrators would otherwise hand every job on this
        host the machine.

        Adopted rather than recreated when it already exists: a reboot must not
        orphan the profile, the workspace and the warm cache under it. The
        password is rotated on every boot regardless, because the previous one was
        only ever needed to register a service that is about to be re-registered.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Index)

    $user = Get-SlotUserName -Index $Index
    $secure = Get-SlotPassword

    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $user -Password $secure
    } else {
        New-LocalUser -Name $user -Password $secure -AccountNeverExpires `
            -PasswordNeverExpires -UserMayNotChangePassword `
            -Description "ci-runner-host-pool slot $Index" | Out-Null
    }

    foreach ($group in @('Administrators', 'Remote Desktop Users')) {
        if (Get-LocalGroupMember -Group $group -Member $user -ErrorAction SilentlyContinue) {
            Remove-LocalGroupMember -Group $group -Member $user -ErrorAction SilentlyContinue
            Write-BootLog "phase 1: removed $user from $group"
        }
    }

    foreach ($dir in @((Get-SlotWorkspacePath -Index $Index), (Get-SlotTempPath -Index $Index))) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Protect-CiDirectory -Path $dir -SlotUser $user
    }

    # A PSCredential, not a password. Phase 5 hands this straight to the service
    # registration; nothing in between has any use for the plaintext, and not
    # producing it is cheaper than protecting it.
    Write-BootLog "phase 1: slot $Index provisioned as $user"
    return @{
        Index      = $Index
        User       = $user
        Credential = New-Object System.Management.Automation.PSCredential(".\$user", $secure)
    }
}

function Invoke-Phase1SlotSetup {
    <#
      .SYNOPSIS
        Provision every slot: accounts, directories, ACLs, logon rights.
      .DESCRIPTION
        THE ORDER HERE IS THE SAFETY PROPERTY, AGAIN.

        C:\ci and C:\ci\bin are locked to SYSTEM and Administrators BEFORE the
        first slot account exists. Phase 0 created them with whatever ACL C:\
        hands down, which is harmless while the host has no unprivileged
        principal on it -- and stops being harmless the instant this function
        creates one. C:\ci\bin holds ci-beacon.ps1, which the SCM re-executes as
        LocalSystem on every service restart and every reboot; a slot account able
        to write that file owns SYSTEM on this host without going anywhere near
        the job boundary.

        Logon rights come last and in one write, after every account exists, for
        the reason given in Grant-SlotLogonRight.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Slots)

    Write-BootLog "phase 1: provisioning $Slots slot(s)"
    foreach ($dir in @($script:CiRoot, $script:BinRoot, $script:SlotRoot)) {
        Protect-CiDirectory -Path $dir
    }
    Write-BootLog 'phase 1: C:\ci, C:\ci\bin and C:\ci\slots locked to SYSTEM and Administrators'

    $provisioned = @()
    for ($i = 1; $i -le $Slots; $i++) {
        $provisioned += (Initialize-SlotAccount -Index $i)
    }
    Grant-SlotLogonRight -SlotUsers @($provisioned | ForEach-Object { $_.User })
    return $provisioned
}

# --- phase 7: the dependency cache --------------------------------------------
#
# THIS PHASE FAILS OPEN, AND IT IS THE ONLY ONE THAT DOES
#
# Every other phase in this file ends in Deny-Boot: a host that cannot prove its
# slot boundary must not take a job. This one is the opposite, for the reason
# host-startup.sh gives for provision_shared_cache(). A host with no usable cache
# is a SLOW host; a host that refuses to register over a cache problem is a
# MISSING host, and the pool responds to missing hosts by queueing jobs. Speed is
# worth less than capacity, so every failure below is logged and survived, and the
# phase returns the slots it managed to seed rather than throwing.
#
# The whole body is therefore inside one try/catch. The entry point runs under
# $ErrorActionPreference = 'Stop', so an unexpected throw anywhere in here would
# take the boot down -- which is exactly the trade this phase exists not to make.

function Invoke-BoundedNative {
    <#
      .SYNOPSIS
        Run a native executable under a wall-clock bound. Returns a result with
        .ExitCode (-1 when it was killed or could not be started) and .Error.
      .DESCRIPTION
        THE CALL OPERATOR CANNOT BE ASKED TO GIVE UP

        An `icacls ... /T` or a `robocopy` run through the call operator blocks
        until the child exits, and once it is running there is no timeout to
        consult and no handle to wait on with one. Phase 7's budget is re-read BETWEEN copies, so it
        bounds a cache that is LARGE and nothing else: one call that wedges -- a
        filter driver, an AV scanner, a handle nobody releases -- still holds the
        boot open indefinitely. All of it happens before phase 5 registers an
        agent, and past the 1,200s registration grace drain_decision.sh reads an
        agent-less host as never registered, so the replacement is built from the
        same image and the pool rebuilds hosts forever over one stuck call.

        Start-Process -PassThru hands back a Process, and a Process CAN be waited
        on with a deadline and killed. That is the whole reason this exists.

        It also retires the $ErrorActionPreference dance every one of these call
        sites carried: under `Stop`, `2>&1` on a native command turns each stderr
        line into a terminating NativeCommandError, and icacls writes a per-file
        line there on a tree of any size. Start-Process does not merge the child's
        streams into the pipeline at all -- they go to files, which are read only
        when the call failed, and the first line of that file is the thing a
        reader of the boot log actually wants.

        -1 for both failures to launch and for a kill, because every caller has to
        refuse on both and both existing checks already read -1 as failure:
        `$exit -ne 0` for icacls, and Test-RobocopySuccess, which rejects a
        negative code precisely because a killed robocopy exits with one. .NET's
        Kill() terminates the child with -1, so this names what the child would
        have reported anyway rather than inventing a sentinel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][string[]] $ArgumentList,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $What
    )

    # A bound of zero or less reads as ALREADY OVER, never as unbounded -- the
    # same reading Test-CacheSeedBudgetExpired takes, for the same reason.
    if ($TimeoutSeconds -le 0) {
        return [pscustomobject] @{ ExitCode = -1; Error = "no time left in the phase 7 budget to run $What" }
    }

    # The arguments are passed as a list and NOT quoted. Every path that reaches
    # here is one this file owns -- C:\ci-cache and the staging names built under
    # C:\ci\cache -- so none of them contains a space, and quoting them would be
    # actively wrong for robocopy, which reads a trailing backslash before a quote
    # as an escape and swallows the closing one.
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    $proc = $null
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -NoNewWindow `
            -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            # The short second wait is so the exit code and the handles are
            # settled before the finally block disposes it. Neither call can
            # change the verdict -- the call is refused either way -- but a
            # child that exited on its own between the deadline and the Kill(),
            # and one this process is not allowed to signal, both throw here and
            # they are not the same fact, so the log says which.
            $fate = 'was killed'
            try {
                $proc.Kill()
                [void] $proc.WaitForExit(5000)
            } catch {
                $fate = "could not be killed: $($_.Exception.Message)"
            }
            return [pscustomobject] @{
                ExitCode = -1
                Error    = "$What did not finish within $TimeoutSeconds" + "s and $fate"
            }
        }
        # The no-argument wait after the bounded one is not redundant: the timed
        # overload can return once the process object sees the exit while the
        # redirected streams are still being drained, and ExitCode is only settled
        # after the full wait.
        $proc.WaitForExit()
        $text = ''
        if ($proc.ExitCode -ne 0) {
            $text = Format-NativeErrorText -Text ([string] (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue))
        }
        return [pscustomobject] @{ ExitCode = $proc.ExitCode; Error = $text }
    } catch {
        return [pscustomobject] @{ ExitCode = -1; Error = "$What could not be started: $($_.Exception.Message)" }
    } finally {
        if ($proc) { $proc.Dispose() }
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
    }
}

function Get-CacheHydrateBound {
    <#
      .SYNOPSIS
        The hydrate's budget, age bound and size bound, clamped. Pure.
      .DESCRIPTION
        Defaults exist for the host that boots from an older instance template,
        where the key is simply absent -- Terraform validates the live values.

        THE CLAMPS ARE NOT THE SAME CHECK REPEATED. Metadata is not only written
        by Terraform: anyone who can set an instance's metadata can set
        `ci-cache-budget-seconds` to a number that holds registration open for as
        long as they like, and a shape check alone accepts that number. So the
        same ranges Terraform validates are applied again here, on the host, to
        the value the host actually read.

        Mirrors the clamps in host-startup.sh's hydrate_shared_cache_bounded(),
        value for value; the two are meant to be diffable.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string] $Budget,
        [AllowNull()][string] $MaxAgeHours,
        [AllowNull()][string] $MaxBytes
    )

    $clamp = {
        param($Text, $Default, $Low, $High)
        # All-digits or the default. A negative number, a decimal and a word all
        # arrive here as the same thing -- text from a metadata attribute -- and
        # [int] would happily parse the first two into a bound nobody chose.
        if ($Text -notmatch '^[0-9]+$') { return $Default }
        # TryParse, NOT a cast. `[decimal] '9' * 40` overflows and THROWS, and
        # this value came from instance metadata -- so the cast turns a junk
        # attribute into an exception on the boot path of a phase whose entire
        # contract is to fail open. Unparseable is out of range is the default.
        $n = [decimal] 0
        if (-not [decimal]::TryParse($Text, [ref] $n)) { return $Default }
        if ($n -lt $Low) { return $Low }
        if ($n -gt $High) { return $High }
        return [long] $n
    }

    return [pscustomobject] @{
        BudgetSeconds = [int] (& $clamp $Budget $script:CacheHydrateBudgetSeconds 10 300)
        MaxAgeHours   = [int] (& $clamp $MaxAgeHours $script:CacheSnapshotMaxAgeHours 1 720)
        MaxBytes      = [long] (& $clamp $MaxBytes $script:CacheSnapshotMaxBytes 1MB 32GB)
    }
}

function Test-CacheSnapshotPointer {
    <#
      .SYNOPSIS
        May this pointer value name an object in this pool's prefix? Pure.
      .DESCRIPTION
        A WHITELIST, NOT A SANITISER. The pointer is written by the trusted
        publisher, but it is still the one input in the whole hydrate that names a
        path, and this is what keeps it from naming anything but a snapshot in
        this pool's own prefix: no `/`, so no traversal and no other pool; no
        `..`; no leading dot; nothing outside a character set that needs no
        URL encoding, which is also why Invoke-CacheFetch does not carry a general
        percent-encoder and why its absence is not a gap.

        The same predicate as the `*[!A-Za-z0-9._-]* | '' | .*` case in
        host-startup.sh.
    #>
    [CmdletBinding()]
    param([AllowNull()][string] $Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name.StartsWith('.')) { return $false }
    return ($Name -match '^[A-Za-z0-9._-]+$')
}

function Get-CacheExpandBound {
    <#
      .SYNOPSIS
        How many decompressed bytes a snapshot of this compressed size may write. Pure.
      .DESCRIPTION
        The size bound and the free-space check both speak about the COMPRESSED
        archive, and gzip expands by more than a thousandfold on the right input:
        a 4 MiB tarball can fill the boot disk. This is the number the unpack is
        allowed to write and the number the free-space check reserves -- the same
        one, deliberately, because unpacking past what was reserved is the failure
        the reservation exists to prevent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][long] $CompressedBytes)
    $bound = $CompressedBytes * 8
    if ($bound -lt $script:CacheExpandFloorBytes) { return [long] $script:CacheExpandFloorBytes }
    return [long] $bound
}

function Get-CacheSnapshotRefusal {
    <#
      .SYNOPSIS
        Why this snapshot must not be unpacked, or '' if it may be. Pure.
      .DESCRIPTION
        Age, size and free space, decided together and before a single byte of the
        archive is downloaded. Pure so that the three bounds the whole layer rests
        on are asserted by a test rather than by a host that has already
        registered agents -- and so the refusal NAMES which bound it was, which is
        the lesson the Linux scan had to be taught the expensive way.

        Free space is reserved against Get-CacheExpandBound rather than against
        the compressed size: filling the boot disk to warm a cache costs this host
        every job it was about to run, which is a far worse trade than starting
        cold.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $AgeHours,
        [Parameter(Mandatory = $true)][long] $Bytes,
        [Parameter(Mandatory = $true)][int] $MaxAgeHours,
        [Parameter(Mandatory = $true)][long] $MaxBytes,
        [Parameter(Mandatory = $true)][long] $FreeBytes
    )

    if ($AgeHours -ge $MaxAgeHours) { return "too-old" }
    if ($Bytes -gt $MaxBytes) { return "too-big" }
    # BOTH AT ONCE. The compressed archive stays in C:\ci-cache.download for the
    # whole of the unpack -- it is what tar is reading -- so the disk has to hold
    # the archive AND everything it expands to. Reserving only the expansion
    # passed a 4 GB snapshot with 32 GB free and then needed 36 GB, which fills
    # the boot volume of a host that was about to run jobs.
    if ($FreeBytes -lt ((Get-CacheExpandBound -CompressedBytes $Bytes) + $Bytes)) { return "no-space" }
    return ''
}

function Get-CacheMetadataResult {
    <#
      .SYNOPSIS
        Read one metadata attribute WITHOUT failing the boot. Value plus reachability.
      .DESCRIPTION
        Get-MetadataValue calls Deny-Boot on anything that is not a 404, and that
        is right for every attribute it reads: an unread ci-job-service-account
        silently converts a broker pool into a no-broker pool. None of that
        applies here. The cache layer fails OPEN by design -- a host with no
        usable cache is a slow host, a host that refuses to register over a cache
        problem is a missing host, and the pool answers a missing host by queueing
        jobs. So this reader hands the failure back instead of taking the host
        down with it.

        `Unreachable` is not cosmetic. An unset `ci-cache-bucket` is the correct
        steady state of a pool that never wanted this layer, and the alert on
        hydrate failures excludes exactly that verdict. Reported the same way, a
        metadata read that failed at boot would file itself into the silenced
        bucket: a pool with a bucket configured, hydrating nothing, reporting the
        verdict that means "nothing to do".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        # BOTH SHAPES, because this reader serves two kinds of attribute.
        # Invoke-RestMethod deserializes by content type, so the plain-text
        # attributes (`ci-cache-bucket` and friends) come back as strings and the
        # service-account token comes back as an OBJECT. Casting that object to
        # a string yields `@{access_token=...; expires_in=...}` -- which is not
        # JSON, and a caller matching a JSON regex against it finds nothing and
        # reports "no token" on a host whose token arrived perfectly. `Object` is
        # the undamaged response; `Value` stays what every text caller expects.
        $raw = Invoke-RestMethod `
            -Uri "$script:MetadataRoot/$Path" `
            -Headers @{ 'Metadata-Flavor' = 'Google' } `
            -TimeoutSec $script:HttpTimeoutSeconds
        return [pscustomobject] @{ Value = [string] $raw; Object = $raw; Unreachable = $false }
    } catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = $_.Exception.Response.StatusCode
        }
        # A 404 is the attribute genuinely not being set. Everything else -- a DNS
        # failure, a refused connection, a read timeout, all of which arrive with
        # no response at all -- is the server not answering, and the two must not
        # be spelled identically.
        return [pscustomobject] @{
            Value       = ''
            Object      = $null
            Unreachable = (-not (Test-MetadataAbsence -StatusCode $status))
        }
    }
}

function Invoke-CacheFetch {
    <#
      .SYNOPSIS
        Download one object from this pool's prefix to a file. $true on success.
      .DESCRIPTION
        The Storage JSON API against a documented URL with the instance's own
        token, for the reason host-startup.sh gives: no dependency on which gcloud
        is on the image and no config directory left behind.

        THE TOKEN NEVER REACHES A COMMAND LINE. On Linux this needed a `-K` file
        descriptor, because `-H "Authorization: Bearer ..."` would put the host
        identity in argv and /proc/<pid>/cmdline is world-readable. Here the
        request is made in-process by this script, which is running as SYSTEM, so
        no child process exists to carry it -- and that is a property to keep
        rather than a coincidence to rely on: nothing in this function may become
        a call to curl.exe or gsutil with the token in its arguments.

        `MaxBytes` bounds the response BEFORE it is all on disk. Without it the
        only bound on a response is the deadline, and C:\ is what fills. It is
        enforced while copying rather than from Content-Length, which the server
        supplies and this host does not control.

        `Accept-Encoding: gzip` is not an optimisation. An object stored with
        `Content-Encoding: gzip` is decompressively transcoded by the service
        unless the client says it accepts gzip, and a transcoded response arrives
        with no Content-Length and expanded past the size its metadata reported.
        Asking for gzip means the bytes arrive exactly as stored. The header is
        set by hand and AutomaticDecompression is deliberately NOT enabled, so
        .NET does not undo it one layer lower.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Bucket,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Prefix,
        [Parameter(Mandatory = $true)][string] $Object,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds,
        [Parameter(Mandatory = $true)][string] $Token,
        [string] $Query = '?alt=media',
        [long] $MaxBytes = 65536
    )

    # A budget already spent is not a one-second budget. Every caller subtracts
    # the elapsed time from the deadline, so this is where "the hydrate is out of
    # time" turns into a refusal rather than into one more request.
    if ($TimeoutSeconds -le 0) { return $false }

    # Only `/` needs encoding -- see Test-CacheSnapshotPointer for why nothing
    # else can be here.
    $enc = ($Prefix + $Object) -replace '/', '%2F'
    $uri = "https://storage.googleapis.com/storage/v1/b/$Bucket/o/$enc$Query"

    # THE TOTAL, NOT EACH READ. `Timeout` bounds the connect and `ReadWriteTimeout`
    # bounds one Read call, so a response that trickles a byte in just under the
    # per-read limit is unbounded in aggregate -- and phase 7 runs BEFORE agent
    # registration, so that is a host recycled for never registering rather than
    # a slow download. Measure-CacheArchiveExpansion checks its deadline inside
    # its loop for the same reason; this is that check, on the copy.
    $copyDeadline = ([datetime]::UtcNow).AddSeconds($TimeoutSeconds)

    $response = $null
    $stream = $null
    $file = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.Headers.Add('Authorization', "Bearer $Token")
        $request.Headers.Add('Accept-Encoding', 'gzip')
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $file = [System.IO.File]::Create($Destination)
        $buffer = New-Object byte[] 65536
        $total = [long] 0
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $total += $read
            if ([datetime]::UtcNow -gt $copyDeadline) {
                throw "response did not finish inside $TimeoutSeconds seconds"
            }
            if ($total -gt $MaxBytes) {
                # Not truncated and kept: a prefix of an archive is the shape of a
                # partial hydrate, which is the one outcome worse than no hydrate.
                throw "response exceeded $MaxBytes bytes"
            }
            $file.Write($buffer, 0, $read)
        }
        $file.Close(); $file = $null
        return $true
    } catch {
        # The eight discards below are deliberate and the analyzer is right to
        # make them say so. A Dispose that throws during cleanup would REPLACE
        # the real failure with a cleanup failure, and on this function's paths
        # it must not be logged at all: the exception carries the request URI,
        # and the only Authorization header this host ever builds is on the
        # request that produced it.
        if ($file) { try { $file.Close() } catch { $null = $_ } }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        return $false
    } finally {
        if ($file) { try { $file.Dispose() } catch { $null = $_ } }
        if ($stream) { try { $stream.Dispose() } catch { $null = $_ } }
        if ($response) { try { $response.Close() } catch { $null = $_ } }
    }
}

function Measure-CacheArchiveExpansion {
    <#
      .SYNOPSIS
        Decompressed size of a .tar.gz, stopped at Bound+1. -1 if it could not be read.
      .DESCRIPTION
        THE BOUND IS DECIDED BY COUNTING, AND THE UNPACKER'S STATUS IS ONLY THE
        SECOND OPINION. tar exits 0 on a stream cut at a member boundary -- the
        record's zero padding reads as an end-of-archive marker -- so a bound
        enforced only by stopping the unpacker can leave this host with a PARTIAL
        cache it believes is whole, after which the hostility scan passes on a
        subset of what the snapshot carries. host-startup.sh had to learn this and
        added the counting pass for it; this is the same pass.

        Counting stops at Bound+1 rather than at the end, so an archive designed
        to expand forever costs one comparison rather than a disk.

        A read that could not finish returns -1 rather than a number, because a
        number here is a claim that the archive was measured. The deadline is
        checked inside the loop for the same reason the copy in Invoke-CacheFetch
        is bounded inside its loop: a decompression bomb does not answer to a
        connect timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][long] $Bound,
        [Parameter(Mandatory = $true)][datetime] $DeadlineUtc
    )

    # NOT $input: that is an automatic variable, and assigning to it inside a
    # function replaces the pipeline enumerator PowerShell put there.
    $raw = $null
    $gzip = $null
    try {
        $raw = [System.IO.File]::OpenRead($Path)
        $gzip = New-Object System.IO.Compression.GZipStream($raw, [System.IO.Compression.CompressionMode]::Decompress)
        $buffer = New-Object byte[] 65536
        $total = [long] 0
        while ($true) {
            $read = $gzip.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt $Bound) { return [long] ($Bound + 1) }
            if ([datetime]::UtcNow -gt $DeadlineUtc) { return [long] (-1) }
        }
        return $total
    } catch {
        return [long] (-1)
    } finally {
        if ($gzip) { try { $gzip.Dispose() } catch { $null = $_ } }
        if ($raw) { try { $raw.Dispose() } catch { $null = $_ } }
    }
}

# Set only by Expand-CacheSnapshot, when a killed tar could not be confirmed
# dead; read only by Remove-CacheTreeSafely. Script scope because the cleanup
# runs in a `finally` several frames above, which the failing path has no way to
# pass anything to.
$script:CacheStageNotQuiesced = $false

function Remove-CacheTreeSafely {
    <#
      .SYNOPSIS
        Delete a cache tree, unless it cannot be shown to be safe to delete.
      .DESCRIPTION
        Windows PowerShell 5.1 -- which is what runs this file -- FOLLOWS a
        directory junction on `Remove-Item -Recurse` and deletes what it POINTS AT
        rather than the link (PowerShell/PowerShell#621, fixed in 6.0 and never
        backported). Every tree this function is pointed at is either a staging
        tree unpacked from a snapshot or a baked master directory moved aside, and
        both are untrusted build input: `warm_cache_script` is arbitrary code the
        consuming repository supplies, and the snapshot passed through no gate at
        all. Aimed at C:\Windows\System32 that is a host this pool cannot recover,
        executed by SYSTEM, from a cleanup path whose whole job is hygiene.

        So the refusal is to delete at all. A stale tree left on disk costs disk
        and is logged; the other branch costs the machine. The refusal is the same
        one Invoke-Phase7DependencyCache already makes for a retired slot's cache
        copy -- this is that rule, given a name, on the paths the hydrate adds.

        A SCAN THAT COULD NOT FINISH IS NOT A CLEAN SCAN. The enumeration errors
        are captured and any of them refuses: this is a proof of ABSENCE, and
        `-ErrorAction SilentlyContinue` alone spells "there is nothing hostile
        here" and "nobody read it" identically.

        Get-ChildItem -Recurse does not descend a reparse point unless
        -FollowSymlink is given, so the scan itself is safe on the tree it judges;
        and it never returns the starting item, which is why the root is added by
        hand -- a tree whose ROOT is a junction is exactly the case that matters.
    #>
    # ConfirmImpact stays Low deliberately. This runs unattended at boot, where
    # $ConfirmPreference is High and nothing prompts -- the declaration is what
    # lets -WhatIf report the delete instead of doing it. Raising the impact
    # would turn a cleanup into a host that never registers.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    # THE SCAN BELOW IS EVIDENCE ABOUT A TREE NOTHING IS WRITING. If a killed
    # unpacker could not be confirmed dead, it can still create a junction
    # between that scan and the delete, and no ordering closes that window --
    # so the delete is given up rather than re-ordered.
    if ($script:CacheStageNotQuiesced) {
        Write-BootLog ("phase 7: leaving $Path in place -- an unpacker in it could not be confirmed " +
            'stopped, and a recursive delete could follow a reparse point created after the scan')
        return
    }

    $rootErrors = @()
    $treeErrors = @()
    $entries = @(Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -ErrorVariable rootErrors) +
        @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable treeErrors)
    if ($rootErrors.Count -gt 0 -or $treeErrors.Count -gt 0) {
        Write-BootLog ("phase 7: $Path is left on disk -- $($rootErrors.Count + $treeErrors.Count) entr(ies) " +
            'could not be read, so it cannot be shown to be free of reparse points')
        return
    }
    $reason = Get-CacheHostileReason -Entries $entries
    if ($reason) {
        Write-BootLog "phase 7: $Path is left on disk -- $reason, and a recursive delete would follow it"
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove-Item -Recurse')) { return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Protect-CacheMaster {
    <#
      .SYNOPSIS
        Scan and seal C:\ci-cache; $true if a slot may be seeded from it.
      .DESCRIPTION
        THE SCAN RUNS BEFORE THE SEAL, AND THAT ORDER IS THE SAFETY PROPERTY

        Sealing is `icacls /reset /T` followed by an inheritable ACE, and both
        follow a junction. So a scan that ran second would be reporting on a tree
        whose ACL had already been applied somewhere else -- and an ACL applied to
        the wrong tree outlives the boot that applied it. Get-CacheHostileReason
        carries the long form of what is refused and why.

        Get-ChildItem -Recurse does NOT descend through a reparse point unless
        -FollowSymlink is given, so the junction is seen as an entry and not
        walked into. That is the behaviour this scan wants and it is relied upon
        rather than assumed: descending would mean enumerating whatever the
        junction names before deciding whether to refuse it.

        The seal is /reset first and Protect-CiDirectory second. /reset drops every
        explicit ACE below the root and puts those entries back on inheritance;
        protecting the root then defines what they inherit. Reversing the two would
        have /reset strip the protection that was just applied.

        `/C` is deliberately NOT passed to icacls. It continues past per-file
        errors AND still exits 0, so it would turn "half the tree kept an ACE
        granting Everyone write" into a silent success -- the shape of failure this
        function exists to prevent. Without it a file icacls cannot touch is a
        non-zero exit and a refusal to seed, which is the fail-open direction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]] $SlotUsers,
        [datetime] $StartedUtc = [datetime]::UtcNow,
        [string] $Master = $script:CacheMaster
    )

    if (-not (Test-Path -LiteralPath $Master)) {
        Write-BootLog ("phase 7: no $Master on this image -- jobs will run with a cold cache " +
            '(needs a Windows image built after issue #150)')
        return $false
    }

    $root = Get-Item -LiteralPath $Master -Force
    if (-not $root.PSIsContainer) {
        Write-BootLog "phase 7: $Master is not a directory -- jobs will run with a cold cache"
        return $false
    }

    # The root is the FIRST entry on purpose: a master that is itself a junction
    # is the case where everything below it is already somebody else's tree.
    #
    # AND THE ENUMERATION HAS TO SUCCEED BEFORE ITS RESULT MEANS ANYTHING. This
    # scan is a proof of ABSENCE -- "there is no reparse point under here" -- and
    # the only evidence for it is having looked at every entry. A directory that
    # could not be listed is not an entry that came back clean; it is an entry
    # nobody read, and `-ErrorAction SilentlyContinue` alone turns the difference
    # into an empty `$reason`, which is the same value a genuinely clean tree
    # produces. The two must not be spelled identically, for the reason the
    # publisher scan had to be fixed for on the Linux side (de69516, "stop
    # reading an unreadable file as clean").
    #
    # So the errors are captured and a scan that hit any of them refuses. Note
    # which way this fails: it fails the CACHE, not the BOOT -- the host still
    # registers and its jobs run cold, exactly as every other phase-7 refusal
    # does. Fail-closed on the gate is not fail-closed on the host.
    # AND IT IS NOT BOUNDED, DELIBERATELY. The three native calls below run in
    # child processes, and a child process can be killed; this enumeration runs on
    # this thread, inside the filesystem. Windows PowerShell 5.1 offers no way to
    # abandon it -- a runspace with a deadline moves the block to another thread
    # without releasing it, and the host process does not exit while that thread
    # holds an open directory handle, so the "bound" would only change which
    # thread the boot is stuck on. It is also a different failure: the three calls
    # can wedge on a filter driver, an AV scanner or a handle another process
    # holds, whereas this reads a local NTFS tree the IMAGE built, and a volume
    # that cannot be enumerated is a host on which nothing else makes progress
    # either. Recorded rather than fixed (#239 item 4).
    $scanErrors = @()
    $entries = @($root) + @(Get-ChildItem -LiteralPath $Master -Recurse -Force `
            -ErrorAction SilentlyContinue -ErrorVariable scanErrors)
    if ($scanErrors.Count -gt 0) {
        $first = ([string] $scanErrors[0]) -replace '[\x00-\x1f]', ' '
        if ($first.Length -gt 300) { $first = $first.Substring(0, 300) }
        Write-BootLog ("phase 7: could not read all of $Master ($($scanErrors.Count) error(s), " +
            "first: $first) -- the tree cannot be shown to be free of reparse points, so it " +
            'is not sealed or copied; jobs will run with a cold cache')
        return $false
    }
    $reason = Get-CacheHostileReason -Entries $entries
    if ($reason) {
        Write-BootLog ("phase 7: refusing to seed from $Master -- $reason; " +
            'jobs will run with a cold cache')
        return $false
    }

    # OWNERSHIP FIRST, BECAUSE A DACL IS NOT A LIMIT ON THE OWNER
    #
    # Neither /reset nor the grant below changes who OWNS an entry, and Windows
    # gives an object's owner READ_CONTROL and WRITE_DAC whether or not any ACE
    # says so. The owner check is satisfied by a GROUP SID in the token as well
    # as by the user's own, so a warm_cache_script that leaves the tree owned by
    # BUILTIN\Users -- which every slot account is in -- hands each slot the
    # ability to rewrite the ACL of the read-only master and poison what the next
    # boot copies into every other slot. Sealing the DACL without sealing the
    # owner seals nothing.
    #
    # It runs after the scan for the same reason the reset does: /T follows a
    # junction, and an ownership change applied to the wrong tree outlives the
    # boot that applied it.
    # BOTH WALKS ARE BOUNDED, and by what is LEFT of phase 7's budget rather than
    # by a constant: two /T walks over the same tree plus one robocopy per tool
    # per slot share one deadline, so giving each call the remainder is what keeps
    # the phase as a whole inside it. See Invoke-BoundedNative for why the call
    # operator could not be asked to give up, and for where the
    # $ErrorActionPreference dance that used to wrap these two lines went.
    $left = Get-CacheSeedSecondsLeft -ElapsedSeconds (([datetime]::UtcNow - $StartedUtc).TotalSeconds) `
        -BudgetSeconds $script:CacheSeedBudgetSeconds
    $owner = Invoke-BoundedNative -FilePath 'icacls.exe' -TimeoutSeconds $left `
        -ArgumentList @($Master, '/setowner', '*S-1-5-32-544', '/T', '/Q') `
        -What "icacls /setowner on $Master"
    if ($owner.ExitCode -ne 0) {
        $detail = ''
        if ($owner.Error) { $detail = ": $($owner.Error)" }
        Write-BootLog ("phase 7: icacls could not take ownership of $Master " +
            "(exit $($owner.ExitCode)$detail) -- " +
            'an entry a slot still owns is an entry that slot can re-grant itself, so nothing ' +
            'is seeded from this tree; cold cache')
        return $false
    }
    $left = Get-CacheSeedSecondsLeft -ElapsedSeconds (([datetime]::UtcNow - $StartedUtc).TotalSeconds) `
        -BudgetSeconds $script:CacheSeedBudgetSeconds
    $reset = Invoke-BoundedNative -FilePath 'icacls.exe' -TimeoutSeconds $left `
        -ArgumentList @($Master, '/reset', '/T', '/Q') `
        -What "icacls /reset on $Master"
    if ($reset.ExitCode -ne 0) {
        $detail = ''
        if ($reset.Error) { $detail = ": $($reset.Error)" }
        Write-BootLog ("phase 7: icacls could not reset the ACLs under $Master " +
            "(exit $($reset.ExitCode)$detail) -- " +
            'refusing to seed from a tree whose permissions are not proven; cold cache')
        return $false
    }

    # SYSTEM and Administrators full, every slot READ-AND-EXECUTE and nothing
    # more. Protect-CiDirectory grants by well-known SID rather than by group
    # name, which is what keeps this working on a localised image -- 'BUILTIN\
    # Administrators' is 'BUILTIN\Administratoren' on a German one, and an icacls
    # line that fails to resolve a name is an ACL that was never applied while the
    # boot carries on.
    Protect-CiDirectory -Path $Master -ReadOnlyUser $SlotUsers
    Write-BootLog "phase 7: $Master sealed read-and-execute to $($SlotUsers -join ', ')"
    return $true
}

function Get-CacheMasterSize {
    <#
      .SYNOPSIS
        Bytes held by the master cache. 0 when it is empty or unreadable.
    #>
    [CmdletBinding()]
    param([string] $Master = $script:CacheMaster)
    $sum = (Get-ChildItem -LiteralPath $Master -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long] 0 }
    return [long] $sum
}

function Get-CacheVolumeFreeByte {
    <#
      .SYNOPSIS
        Free bytes on the volume the per-slot copies land on.
      .DESCRIPTION
        [System.IO.DriveInfo] rather than Get-Volume or Get-PSDrive: it is the one
        that reports the free space available TO THE CALLER, and it needs no
        storage module on the image.
    #>
    [CmdletBinding()]
    param([string] $Path = $script:CacheSlots)
    $qualifier = Split-Path -Qualifier $Path
    return [long] ([System.IO.DriveInfo]::new($qualifier + '\')).AvailableFreeSpace
}

function Expand-CacheSnapshot {
    <#
      .SYNOPSIS
        Unpack a measured snapshot into the staging tree. $true on success.
      .DESCRIPTION
        `tar.exe` is bsdtar, in System32 on every Windows Server image this pool
        builds from. It is called AFTER Measure-CacheArchiveExpansion has already
        decided the archive is within its bound, so this step is not what enforces
        the bound -- tar exits 0 on a stream cut at a member boundary, which is
        exactly why the counting pass exists.

        WHAT MUST NEVER BE ADDED TO THIS COMMAND LINE: `-P` / `--absolute-paths`.
        The staging tree is what confines an adversarial archive, and it is tar's
        DEFAULTS that confine it -- a leading `/` and a leading `../` are stripped,
        and a member landing outside the extraction root is refused. `-P` turns
        that off, and the scan afterwards only ever sees what stayed inside the
        tree.

        The deadline binds tar because a large archive is where the budget
        actually goes. tar spawns nothing, which is what makes a plain wait-then-
        kill sufficient here and is not true of the snapshot BUILD's install step
        -- that one runs arbitrary repository code and needs a job object.

        The process HANDLE is what is waited on and killed, never a pid looked up
        again afterwards: holding the object is what stops Windows recycling the
        number under this function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Archive,
        [Parameter(Mandatory = $true)][string] $Stage,
        [Parameter(Mandatory = $true)][datetime] $DeadlineUtc
    )

    $seconds = [int] ([datetime]::UtcNow).Subtract($DeadlineUtc).Negate().TotalSeconds
    if ($seconds -le 0) { return $false }

    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) {
        Write-BootLog "phase 7: no $tar on this image -- a snapshot cannot be unpacked"
        return $false
    }

    $proc = $null
    try {
        $proc = Start-Process -FilePath $tar `
            -ArgumentList @('-x', '-z', '-f', $Archive, '-C', $Stage) `
            -NoNewWindow -PassThru
        if (-not $proc.WaitForExit($seconds * 1000)) {
            # KILL IS A REQUEST, NOT AN EVENT. It returns as soon as the
            # termination is queued, and returning here hands control to the
            # caller's `finally`, which scans the staging tree and then
            # recursively deletes what scanned clean -- while tar may still be
            # writing into it. An archive member that is a reparse point, created
            # in that window, is followed by 5.1's Remove-Item and deletes what it
            # points at, as SYSTEM. So the exit is waited for; and if it cannot be
            # confirmed, the tree is declared un-quiesced and left alone. A stale
            # staging tree costs disk on an ephemeral host. The other branch costs
            # the host.
            try { $proc.Kill() } catch { $null = $_ }
            if (-not $proc.WaitForExit(10000)) {
                $script:CacheStageNotQuiesced = $true
                Write-BootLog ('phase 7: the unpacker did not exit after being killed -- leaving the ' +
                    'staging tree in place rather than deleting a tree something may still be writing')
            }
            return $false
        }
        return ($proc.ExitCode -eq 0)
    } catch {
        return $false
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { $null = $_ } }
    }
}

function Get-CacheStagedEntry {
    <#
      .SYNOPSIS
        Every entry under a staged tree, with a deadline. Reports what it could
        not read and whether it ran out of time.
      .DESCRIPTION
        WHY NOT `Get-ChildItem -Recurse`. One call, however long it takes: an
        archive inside the size bound can still hold a very large number of very
        small entries, and a filter driver can slow enumeration by an order of
        magnitude. Phase 7 runs BEFORE agent registration, so an unbounded scan is
        the advertised budget quietly not applying to the last step of the
        sequence -- the same gap the download copy and the expansion measurement
        each had to close inside their own loops.

        So the walk is explicit and the deadline is checked once per directory.
        `TimedOut` returns NO entries at all, deliberately: a partial listing is
        the one shape a hostility scan must never be handed, because it is a proof
        of absence and half a tree proves nothing about the other half.

        A REPARSE POINT IS JUDGED, NEVER ENTERED. Get-ChildItem -Recurse does not
        descend one unless asked, and the queue here does not either -- the entry
        is returned so Get-CacheHostileReason can refuse the whole tree over it.

        `Failed` counts what could not be read. An enumeration error is not an
        empty directory, and reporting them identically is how a scan starts
        saying "clean" about a tree nobody managed to look at.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][datetime] $DeadlineUtc
    )

    $entries = New-Object System.Collections.ArrayList
    $failed = 0

    $rootErrors = @()
    foreach ($r in @(Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -ErrorVariable rootErrors)) {
        [void] $entries.Add($r)
    }
    $failed += $rootErrors.Count

    $queue = New-Object System.Collections.Queue
    [void] $queue.Enqueue($Path)
    while ($queue.Count -gt 0) {
        if ([datetime]::UtcNow -gt $DeadlineUtc) {
            return [pscustomobject] @{ Entries = @(); Failed = $failed; TimedOut = $true }
        }
        $dir = $queue.Dequeue()
        $dirErrors = @()
        $kids = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable dirErrors)
        $failed += $dirErrors.Count
        foreach ($k in $kids) {
            [void] $entries.Add($k)
            if ($k.PSIsContainer -and -not ($k.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                [void] $queue.Enqueue($k.FullName)
            }
        }
    }
    return [pscustomobject] @{ Entries = $entries.ToArray(); Failed = $failed; TimedOut = $false }
}

function Update-CacheMasterFromStage {
    <#
      .SYNOPSIS
        Move the staged tool directories into the master. Returns how many moved.
      .DESCRIPTION
        ONLY THE TOOL DIRECTORIES THIS HOST KNOWS ABOUT, BY NAME. A snapshot
        cannot introduce a new top-level entry into the master: anything the
        archive holds that is not in $script:CacheDirs is dropped with the staging
        tree, so a name added to the publisher has to be added here -- and
        reviewed -- before it can arrive.

        A directory is REPLACED rather than merged. The snapshot is produced from
        this same image, so it is a superset of what was baked; a merge would be
        slower, would not be atomic, and would leave entries from an expired
        snapshot alive in the master indefinitely, which is the age bound quietly
        failing.

        THE BAKED DIRECTORY IS MOVED ASIDE, NOT DELETED, and only dropped once its
        replacement is in place. Deleting first is one failed rename away from a
        host with neither copy: the snapshot path is allowed to leave the cache as
        cold as it found it, never colder. A rename rather than a copy, because
        both paths are on the same volume, so it costs nothing and cannot half
        finish -- and nothing reads the master until Protect-CacheMaster runs a
        few lines later in this same phase, so there is no reader to tear.

        The aside copy is dropped through Remove-CacheTreeSafely: it is the BAKED
        master, which `warm_cache_script` wrote, and Protect-CacheMaster has not
        scanned it yet at this point in the phase.

        A stale `.previous` is swept before the loop rather than inside it. A boot
        that died between the aside-move and the replacement leaves one behind,
        and a sweep that only ran for directories the NEXT snapshot happens to
        ship would leave it there indefinitely -- a full duplicate cache tree that
        Protect-CacheMaster then publishes read-and-execute to every slot.
    #>
    # Same reasoning as Remove-CacheTreeSafely: declared so -WhatIf is honest,
    # Low so an unattended boot never stops to ask.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)][string] $Stage,
        [string] $Master = $script:CacheMaster
    )

    foreach ($stale in @(Get-ChildItem -LiteralPath $Master -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\.[A-Za-z0-9._-]+\.previous$' })) {
        Remove-CacheTreeSafely -Path $stale.FullName
    }

    $moved = 0
    foreach ($dir in $script:CacheDirs) {
        $source = Join-Path $Stage $dir
        $staged = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
        if (-not $staged) { continue }
        # A DIRECTORY, OR NOTHING. Test-Path is true for a FILE of the same name,
        # and a CACHE_PREPARE that deletes a pre-created tool directory and writes
        # an ordinary file in its place gets that file moved over the baked tree.
        # The damage is downstream: Initialize-SlotCache cannot copy from a file,
        # and because the cache path now EXISTS it does not create the writable
        # fallback either -- so every job on this host is handed cache environment
        # variables pointing at a file and fails, where the whole contract of this
        # phase is that the worst case is running cold.
        if (-not $staged.PSIsContainer) {
            Write-BootLog ("phase 7: the staged snapshot has $dir as a file rather than a directory -- " +
                'leaving the baked one in place')
            continue
        }
        # AN EMPTY DIRECTORY IS NOT A CACHE. The host pre-creates all of
        # $script:CacheDirs at startup, so a snapshot built from a CACHE_PREPARE
        # that only warmed npm still SHIPS an empty maven, nuget and go. Moving
        # those over the baked ones costs this pool the cache its image built,
        # and the verdict still says 'hydrated'. Replacement is only ever an
        # improvement when there is something in the replacement.
        if (-not (Get-ChildItem -LiteralPath $source -Force -ErrorAction SilentlyContinue |
                    Select-Object -First 1)) {
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($dir, 'publish into the cache master')) { continue }
        $target = Join-Path $Master $dir
        $aside = Join-Path $Master ".$dir.previous"
        # A SURVIVING ASIDE IS A REFUSAL, NOT A LEFTOVER. The sweep above drops
        # stale `.previous` trees through Remove-CacheTreeSafely, which
        # DELIBERATELY leaves one it cannot show to be safe -- a junction, or a
        # tree it could not read to the end. `Move-Item -Force` onto an existing
        # directory name does not replace that name, it moves the source INSIDE
        # it, and inside a junction is wherever the junction points: the baked
        # cache written to an arbitrary path as SYSTEM. Protect-CacheMaster a few
        # lines later can refuse the result; it cannot take that write back. So a
        # tool whose aside is still there keeps its baked cache instead.
        if (Test-Path -LiteralPath $aside) {
            Write-BootLog ("phase 7: $dir keeps its baked cache -- $aside survived the sweep, and " +
                'moving the master onto a name this host could not clear is how a junction gets written through')
            continue
        }
        if (Test-Path -LiteralPath $target) {
            try {
                Move-Item -LiteralPath $target -Destination $aside -Force -ErrorAction Stop
            } catch {
                # The baked copy is still in place and still usable. Leaving it is
                # the whole point of moving aside rather than deleting.
                continue
            }
        }
        try {
            Move-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
            $moved++
        } catch {
            if (Test-Path -LiteralPath $aside) {
                Move-Item -LiteralPath $aside -Destination $target -Force -ErrorAction SilentlyContinue
            }
            continue
        }
        Remove-CacheTreeSafely -Path $aside
    }
    return $moved
}

function Invoke-CacheHydrateBounded {
    <#
      .SYNOPSIS
        Replace the baked master with the published snapshot. Returns a verdict.
      .DESCRIPTION
        Every return states a VERDICT and none of them throws. See the section
        header above $script:CacheStage for the four properties this is built on.

        The verdict strings are the same ones host-startup.sh publishes, so a
        Linux pool and a Windows pool describe the same outcome the same way even
        though only one of them has a metric to publish it to.
    #>
    [CmdletBinding()]
    param([string] $Master = $script:CacheMaster)

    # BEFORE THE FIRST READ, not after the last one. Five metadata attributes are
    # read below, each with its own 10-second timeout, so a metadata server that
    # answers slowly but inside those timeouts could spend most of a minute here
    # -- and the budget then started from zero afterwards, which made a documented
    # 60-second phase take nearly two minutes ahead of agent registration.
    $started = [datetime]::UtcNow

    $bucketRead = Get-CacheMetadataResult -Path 'instance/attributes/ci-cache-bucket'
    if ([string]::IsNullOrEmpty($bucketRead.Value)) {
        if ($bucketRead.Unreachable) {
            Write-BootLog ('phase 7: metadata server unreachable -- cannot tell whether a snapshot ' +
                'bucket is configured; this host runs on the cache its image baked')
            return 'no-metadata-server'
        }
        Write-BootLog 'phase 7: no snapshot bucket configured -- this host runs on the cache its image baked'
        return 'not-configured'
    }
    $bucket = $bucketRead.Value

    # The prefix is what the read grant is CONDITIONED on, so an empty one is not
    # a harmless default: it would send every request outside the condition, and
    # the 403s would read in this log as "the snapshot is missing" rather than as
    # a misconfigured pool.
    $prefix = (Get-CacheMetadataResult -Path 'instance/attributes/ci-cache-prefix').Value
    if (-not $prefix.EndsWith('/')) {
        Write-BootLog "phase 7: the cache prefix is not a directory prefix -- skipping the hydrate"
        return 'bad-prefix'
    }

    $bounds = Get-CacheHydrateBound `
        -Budget (Get-CacheMetadataResult -Path 'instance/attributes/ci-cache-budget-seconds').Value `
        -MaxAgeHours (Get-CacheMetadataResult -Path 'instance/attributes/ci-cache-max-age-hours').Value `
        -MaxBytes (Get-CacheMetadataResult -Path 'instance/attributes/ci-cache-max-bytes').Value

    $deadline = $started.AddSeconds($bounds.BudgetSeconds)
    $left = { [int] ([datetime]::UtcNow).Subtract($deadline).Negate().TotalSeconds }

    # The master has to be there to be replaced. Creating one here would hand this
    # pool a cache tree the image never built and Protect-CacheMaster's own
    # message about the image requirement would stop being true; the host runs
    # cold instead, exactly as it does today.
    if (-not (Test-Path -LiteralPath $Master)) {
        Write-BootLog "phase 7: no $Master on this image -- there is nothing for a snapshot to replace"
        return 'no-master'
    }
    # The ROOT only, and before anything is moved INTO it. A master that is itself
    # a junction turns every move below into a write somewhere nobody chose. The
    # recursive scan is Protect-CacheMaster's, a few lines later; this is the one
    # question that has to be answered BEFORE the moves rather than after them.
    $rootReason = Get-CacheHostileReason -Entries @(Get-Item -LiteralPath $Master -Force -ErrorAction SilentlyContinue)
    if ($rootReason) {
        Write-BootLog "phase 7: not hydrating $Master -- $rootReason"
        return 'master-hostile'
    }

    # THE READS ABOVE ARE INSIDE THE BUDGET, AND THEY CAN SPEND IT. Five metadata
    # attributes at ten seconds each, plus the token below, is a minute of fixed
    # timeouts in front of a sixty-second phase; `& $left` bounds every FETCH
    # after this point, but nothing bounded the token read itself. If the budget
    # is already gone there is no snapshot this host can finish, so it says so
    # rather than spending another ten seconds proving it.
    if ((& $left) -le 0) {
        Write-BootLog ("phase 7: the $($bounds.BudgetSeconds)s budget was spent reading cache " +
            'metadata -- starting cold instead')
        return 'budget-spent'
    }

    # THE PROPERTY, NOT A REGEX OVER THE STRINGIFIED OBJECT. Invoke-RestMethod
    # has already parsed this response; `[string]` on the result gives
    # `@{access_token=...}`, which no JSON pattern matches, so the regex form
    # returned 'no-token' on every host and the whole pool quietly stayed on the
    # baked cache. The broker readiness code a few hundred lines below reads the
    # same endpoint the same way.
    $tokenResult = Get-CacheMetadataResult -Path 'instance/service-accounts/default/token'
    $token = ''
    if ($tokenResult.Object -and $tokenResult.Object.access_token) {
        $token = [string] $tokenResult.Object.access_token
    }
    if (-not $token) {
        Write-BootLog 'phase 7: no instance token -- skipping the cache hydrate'
        return 'no-token'
    }

    # Root-owned from creation, under a name no slot account can reach: SYSTEM is
    # about to unpack an archive into it, and nothing else on this host may read,
    # still less substitute, a name inside it. Both trees are removed through
    # Remove-CacheTreeSafely on every path out of this function.
    Remove-CacheTreeSafely -Path $script:CacheDownload
    Remove-CacheTreeSafely -Path $script:CacheStage
    if ((Test-Path -LiteralPath $script:CacheDownload) -or (Test-Path -LiteralPath $script:CacheStage)) {
        Write-BootLog 'phase 7: a previous hydrate left a tree that cannot safely be removed -- skipping'
        return 'no-scratch'
    }
    try {
        New-Item -ItemType Directory -Force -Path $script:CacheDownload -ErrorAction Stop | Out-Null
        New-Item -ItemType Directory -Force -Path $script:CacheStage -ErrorAction Stop | Out-Null
        Protect-CiDirectory -Path $script:CacheDownload
        Protect-CiDirectory -Path $script:CacheStage
    } catch {
        Write-BootLog "phase 7: could not create the hydrate scratch directories: $($_.Exception.Message)"
        return 'no-scratch'
    }

    try {
        $fetch = @{ Bucket = $bucket; Prefix = $prefix; Token = $token }

        # The pointer names the current snapshot. It is a separate, tiny object
        # because the snapshots themselves must never be overwritten: the bucket
        # measures age per generation and an overwrite starts a new one at zero, so
        # a snapshot key rewritten in place would never reach the age bound and
        # never expire.
        $pointerFile = Join-Path $script:CacheDownload 'current'
        if (-not (Invoke-CacheFetch @fetch -Object 'current' -Destination $pointerFile `
                    -TimeoutSeconds (& $left) -MaxBytes $script:CachePointerMaxBytes)) {
            Write-BootLog 'phase 7: no cache snapshot published for this pool yet -- running on the baked cache'
            return 'no-snapshot'
        }
        $snapshot = ''
        $firstLine = @(Get-Content -LiteralPath $pointerFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($firstLine.Count -gt 0) { $snapshot = ([string] $firstLine[0]).Trim() }
        if (-not (Test-CacheSnapshotPointer -Name $snapshot)) {
            # The rejected name is NOT echoed. It is the one fully attacker-
            # controlled string in this function, it has not been validated at the
            # point this line runs, and this log is read in a terminal.
            Write-BootLog ("phase 7: the cache pointer does not name a snapshot in this pool's prefix " +
                "($($snapshot.Length) bytes) -- ignoring it")
            return 'bad-pointer'
        }

        # Size and creation time from the SERVICE, not from the name: a timestamp
        # encoded in an object name is written by whoever wrote the object, and the
        # age bound is worth having only if it reads the one that cannot be
        # backdated.
        $metaFile = Join-Path $script:CacheDownload 'meta.json'
        if (-not (Invoke-CacheFetch @fetch -Object $snapshot -Destination $metaFile `
                    -TimeoutSeconds (& $left) -Query '?fields=timeCreated,size,generation' `
                    -MaxBytes $script:CachePointerMaxBytes)) {
            Write-BootLog ("phase 7: cache snapshot $snapshot is named by the pointer but could not be " +
                'read -- running on the baked cache')
            return 'unreadable'
        }
        $meta = $null
        try { $meta = Get-Content -LiteralPath $metaFile -Raw | ConvertFrom-Json } catch { $meta = $null }
        $created = [datetime]::MinValue
        $size = [long] 0
        $generation = ''
        if ($meta) {
            $generation = [string] $meta.generation
            [void][long]::TryParse([string] $meta.size, [ref] $size)
            [void][datetime]::TryParse([string] $meta.timeCreated, [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
                [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref] $created)
        }
        if ($created -eq [datetime]::MinValue -or $size -le 0 -or $generation -notmatch '^[0-9]+$') {
            Write-BootLog ("phase 7: cache snapshot $snapshot has no readable size, generation or " +
                'creation time -- refusing it')
            return 'no-metadata'
        }

        # FLOOR, not [int]'s banker's rounding: 167.6 hours became 168 and a
        # snapshot inside a 168-hour bound was refused for being at it. The Linux
        # half computes this with integer division and means the same thing.
        $age = [int] [math]::Floor($started.Subtract($created).TotalHours)

        # RECORDED BEFORE THE BOUNDS THAT MAY REJECT IT, exactly as on Linux. A
        # `too-old` verdict is only actionable next to the age that produced it:
        # published only on the paths that accepted the snapshot, the age series
        # would be empty for every pool whose snapshot expired -- which is the one
        # case an operator opens the chart for.
        $script:CacheSnapAgeHours = $age
        $script:CacheSnapBytes = $size

        $refusal = Get-CacheSnapshotRefusal -AgeHours $age -Bytes $size `
            -MaxAgeHours $bounds.MaxAgeHours -MaxBytes $bounds.MaxBytes `
            -FreeBytes (Get-CacheVolumeFreeByte -Path $Master)
        if ($refusal) {
            Write-BootLog ("phase 7: refusing cache snapshot $snapshot -- $refusal (${age}h old, $size bytes, " +
                "bounds $($bounds.MaxAgeHours)h / $($bounds.MaxBytes) bytes); starting cold instead")
            return $refusal
        }

        # THE GENERATION IS PINNED, so that what was measured is what is
        # downloaded. Age, size and free space were all asserted against the
        # metadata above; without pinning, the object could be replaced in between
        # and every one of those bounds would have been checked against a
        # generation that no longer exists. "Snapshots are written once" is the
        # publisher's convention -- it is not a control this host can enforce, so
        # this host does not rely on it.
        $archive = Join-Path $script:CacheDownload 'snapshot.tar.gz'
        if (-not (Invoke-CacheFetch @fetch -Object $snapshot -Destination $archive `
                    -TimeoutSeconds (& $left) -Query "?alt=media&generation=$generation" -MaxBytes $size)) {
            Write-BootLog ("phase 7: cache snapshot $snapshot did not download inside the " +
                "$($bounds.BudgetSeconds)s budget -- starting cold instead")
            return 'download-timeout'
        }

        $bound = Get-CacheExpandBound -CompressedBytes $size
        $expanded = Measure-CacheArchiveExpansion -Path $archive -Bound $bound -DeadlineUtc $deadline
        if ($expanded -lt 0) {
            Write-BootLog ("phase 7: cache snapshot $snapshot could not be measured inside the " +
                "$($bounds.BudgetSeconds)s budget -- starting cold rather than unpacking an archive " +
                'nothing bounded')
            return 'unpack-timeout'
        }
        if ($expanded -gt $bound) {
            Write-BootLog ("phase 7: cache snapshot $snapshot expands past the $bound byte bound -- " +
                'refusing it rather than unpacking part of it')
            return 'too-big-expanded'
        }
        if (-not (Expand-CacheSnapshot -Archive $archive -Stage $script:CacheStage -DeadlineUtc $deadline)) {
            Write-BootLog ("phase 7: cache snapshot $snapshot did not unpack inside the " +
                "$($bounds.BudgetSeconds)s budget -- starting cold instead")
            return 'unpack-timeout'
        }

        # THE SAME SCAN Protect-CacheMaster RUNS, on content that passed through no
        # image build. A snapshot is the one way into this tree that no reviewed
        # build step stands in front of, and this is where it is stopped -- in the
        # staging tree, before a single directory reaches the master.
        $scan = Get-CacheStagedEntry -Path $script:CacheStage -DeadlineUtc $deadline
        if ($scan.TimedOut) {
            Write-BootLog ("phase 7: the staged snapshot could not be scanned inside the " +
                "$($bounds.BudgetSeconds)s budget -- starting cold rather than publishing a tree " +
                'this host never finished reading')
            return 'scan-timeout'
        }
        if ($scan.Failed -gt 0) {
            Write-BootLog ("phase 7: could not read all of the staged snapshot " +
                "($($scan.Failed) error(s)) -- it cannot be shown to be free of " +
                'reparse points, so nothing from it reaches the master')
            return 'scan-refused'
        }
        $reason = Get-CacheHostileReason -Entries $scan.Entries
        if ($reason) {
            Write-BootLog ("phase 7: cache snapshot $snapshot rejected by the same scan the image build " +
                "runs -- $reason; starting cold instead")
            return 'scan-refused'
        }

        # AND THE SECOND WAY ONE FILE GETS TWO ACLS. A reparse point is one name
        # standing for another tree; a hardlink is two names for one file, sharing
        # one security descriptor -- so `icacls /reset /T` over this tree rewrites
        # the ACL of whatever the other name is, wherever it lives. The scan above
        # cannot see it: nothing in a directory entry says how many names a file
        # has. This runs on the staged tree, before anything reaches the master,
        # for exactly the reason the scan above does.
        if (-not (Initialize-CacheLinkProbe)) {
            Write-BootLog ("phase 7: cache snapshot $snapshot cannot be checked for out-of-tree " +
                'hardlinks on this host -- starting cold rather than sealing a tree whose ACL ' +
                'walk might land somewhere else')
            return 'scan-refused'
        }
        $links = Get-CacheLinkRecord -Entries $scan.Entries -DeadlineUtc $deadline
        if ($links.TimedOut) {
            Write-BootLog ("phase 7: the staged snapshot could not be checked for hardlinks inside " +
                "the $($bounds.BudgetSeconds)s budget -- starting cold instead")
            return 'scan-timeout'
        }
        if ($links.Failed -gt 0) {
            Write-BootLog ("phase 7: could not read the link count of all of the staged snapshot " +
                "($($links.Failed) file(s)) -- it cannot be shown to be free of out-of-tree " +
                'hardlinks, so nothing from it reaches the master')
            return 'scan-refused'
        }
        $linkReason = Get-CacheHardlinkReason -Records $links.Records
        if ($linkReason) {
            Write-BootLog ("phase 7: cache snapshot $snapshot rejected by the same scan the image build " +
                "runs -- $linkReason; starting cold instead")
            return 'scan-refused'
        }

        # The scan finished in time; the moves are what is left, and they are
        # renames within one volume. Starting them past the deadline would be the
        # budget expiring between the last two statements of the phase.
        if ([datetime]::UtcNow -gt $deadline) {
            Write-BootLog ("phase 7: the $($bounds.BudgetSeconds)s budget ran out before the staged " +
                'snapshot could be published -- starting cold instead')
            return 'scan-timeout'
        }
        $moved = Update-CacheMasterFromStage -Stage $script:CacheStage -Master $Master
        $script:CacheDirsHydrated = $moved
        $took = [int] ([datetime]::UtcNow).Subtract($started).TotalSeconds
        Write-BootLog ("phase 7: cache hydrated from $snapshot -- $moved tool cache(s), $size bytes, " +
            "${age}h old, ${took}s of a $($bounds.BudgetSeconds)s budget")
        if ($moved -eq 0) { return 'hydrated-nothing' }
        return 'hydrated'
    } finally {
        # On EVERY path out, including the ones a later edit adds -- and through
        # the scanning delete, because the staging tree holds an archive this host
        # did not build.
        Remove-CacheTreeSafely -Path $script:CacheDownload
        Remove-CacheTreeSafely -Path $script:CacheStage
    }
}

# --- the telemetry the hydrate is judged by ----------------------------------
#
# ONE publisher, mirroring modules/ci-runner-host-pool/scripts/telemetry.sh --
# the shape to mirror, not to reuse: the shell file is concatenated ahead of the
# two bash startup scripts and cannot be dot-sourced here.
#
# The five series, their names, their resource type and their labels are the
# Linux ones exactly. That is the whole point: `ci_cache_hydrate_verdict` grouped
# by `verdict` has to answer for every pool in the fleet, and the alert policy
# ensure-alert-policies.sh installs is written once against one filter.
#
# The host account already holds roles/monitoring.metricWriter -- the same grant
# that lets the Linux host in this same module publish -- so this costs no new
# permission on a machine that runs pull-request code. It is the SAME instance
# template: modules/ci-runner-host-pool/main.tf gives every host `ci-metric-
# prefix`, and the service account is bound in one place for both host kinds.
#
# It never fails a boot. A host that cannot publish still registers: the metric
# exists to explain a slow pool, and refusing to serve jobs because the
# explanation did not send would be the monitoring deciding the availability.

$script:MetricBuffer = @()

function Initialize-CacheTelemetry {
    <#
      .SYNOPSIS
        Record who this host is, for the publisher. No network.
      .DESCRIPTION
        Phase 0 reads every static attribute exactly once, and these are static
        attributes. Reading them from inside phase 7 instead would put a metadata
        call on the hydrate's own budget and give this file a second read site.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Config)

    $script:MetricPrefix = [string] $Config.MetricPrefix
    $script:MetricProject = [string] $Config.ProjectId
    $script:MetricRegion = ConvertTo-MetricRegion -Zone ([string] $Config.Zone)
    $script:MetricPool = [string] $Config.Pool
    # Empty when either half is, rather than the "/" that concatenating two empty
    # reads would produce: the flush skips on an empty repo, and "/" is not empty
    # -- it is a resource label that publishes and cannot be grouped by.
    $script:MetricRepo = ''
    if (-not [string]::IsNullOrWhiteSpace($Config.Owner) -and
        -not [string]::IsNullOrWhiteSpace($Config.Repo)) {
        $script:MetricRepo = "$($Config.Owner)/$($Config.Repo)"
    }
}

function Add-MetricSeries {
    <#
      .SYNOPSIS
        Buffer one point. Cloud Monitoring rejects two points for one series.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][double] $Value,
        [hashtable] $ExtraLabels
    )
    $script:MetricBuffer += , (ConvertTo-MetricPoint -Name $Name -Value $Value `
            -MetricPrefix $script:MetricPrefix -Project $script:MetricProject `
            -Region $script:MetricRegion -Repo $script:MetricRepo -Pool $script:MetricPool `
            -ExtraLabels $ExtraLabels)
}

function Send-MetricSeries {
    <#
      .SYNOPSIS
        One API call for everything buffered. $true when it landed.
      .DESCRIPTION
        The token is read through Get-CacheMetadataResult, which hands its failure
        back instead of taking the host down with it -- Get-MetadataValue would
        Deny-Boot, and a boot lost to an unpublished metric is the monitoring
        deciding the availability.

        The token never reaches a command line. host-startup.sh has to work to
        achieve that -- it pipes a curl config over a file descriptor, because
        `-H "Authorization: Bearer $token"` would put the instance's token in a
        world-readable /proc/<pid>/cmdline while job code runs on the same host.
        Here the header is a hashtable passed in-process to Invoke-RestMethod and
        nothing is exec'd, so there is no argv to leak into. Worth stating,
        because the obvious "port" of that code would be to shell out to curl.

        Bounded by $script:HttpTimeoutSeconds, like every call this host makes:
        this flush sits on the boot path, in front of the agent registering.
    #>
    [CmdletBinding()]
    param()

    if ($script:MetricBuffer.Count -eq 0) { return $true }
    $body = @{ timeSeries = $script:MetricBuffer } | ConvertTo-Json -Depth 12 -Compress
    $script:MetricBuffer = @()

    $tokenResult = Get-CacheMetadataResult -Path 'instance/service-accounts/default/token'
    $token = ''
    if ($tokenResult.Object -and $tokenResult.Object.access_token) {
        $token = [string] $tokenResult.Object.access_token
    }
    if (-not $token) {
        Write-BootLog 'phase 7: no instance token -- cache telemetry not published'
        return $false
    }

    try {
        $null = Invoke-RestMethod -Method Post `
            -Uri "https://monitoring.googleapis.com/v3/projects/$script:MetricProject/timeSeries" `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType 'application/json' `
            -Body $body `
            -TimeoutSec $script:HttpTimeoutSeconds
        return $true
    } catch {
        # Loud, for the reason telemetry.sh gives: a silent telemetry failure is
        # worse than no telemetry, because the chart that would have shown the
        # gap is the chart that stops moving.
        Write-BootLog "phase 7: cache telemetry did not publish: $($_.Exception.Message)"
        return $false
    }
}

function Publish-CacheTelemetry {
    <#
      .SYNOPSIS
        The five hydrate series, once per boot.
      .DESCRIPTION
        Called from Invoke-CacheHydrate rather than from the returns that decided
        the verdict, for the same reason the verdict itself is logged there: a
        rule that has to be repeated at every return is a rule that will be missed
        at the next one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Verdict,
        [Parameter(Mandatory = $true)][int] $Seconds
    )

    # All four, not just the two the URL needs: project and region are resource
    # labels and so are pool and repo, and an empty one produces a request the API
    # rejects whole -- one missing metadata read would drop every series in this
    # flush and log a 400 nobody reads, rather than skipping cleanly.
    if ([string]::IsNullOrWhiteSpace($script:MetricPrefix) -or
        [string]::IsNullOrWhiteSpace($script:MetricProject) -or
        [string]::IsNullOrWhiteSpace($script:MetricRegion) -or
        [string]::IsNullOrWhiteSpace($script:MetricPool) -or
        [string]::IsNullOrWhiteSpace($script:MetricRepo)) {
        return $false
    }

    # An empty verdict means the hydrate returned through a path that states
    # none, which is a bug in this file rather than a state of the cache. Named
    # rather than dropped, because a verdict that silently stops being published
    # looks exactly like a pool that stopped hydrating.
    $stated = $Verdict
    if ([string]::IsNullOrWhiteSpace($stated)) { $stated = 'unset' }
    Add-MetricSeries -Name 'ci_cache_hydrate_verdict' -Value 1 -ExtraLabels @{ verdict = $stated }
    Add-MetricSeries -Name 'ci_cache_hydrate_seconds' -Value $Seconds

    # Age, size and count only when a snapshot was actually read -- a zero on a
    # pool with no bucket configured would sit in the same series as a zero on a
    # pool whose snapshot is fresh, and an alert cannot tell those apart.
    if ($null -ne $script:CacheSnapAgeHours) {
        Add-MetricSeries -Name 'ci_cache_snapshot_age_hours' -Value $script:CacheSnapAgeHours
    }
    if ($null -ne $script:CacheSnapBytes) {
        Add-MetricSeries -Name 'ci_cache_snapshot_bytes' -Value $script:CacheSnapBytes
    }
    if ($null -ne $script:CacheDirsHydrated) {
        Add-MetricSeries -Name 'ci_cache_dirs_hydrated' -Value $script:CacheDirsHydrated
    }

    return (Send-MetricSeries)
}

function Invoke-CacheHydrate {
    <#
      .SYNOPSIS
        Run the hydrate and state its verdict, once, on every path out.
      .DESCRIPTION
        WHY THE VERDICT IS PUBLISHED HERE AND NOT AT THE RETURN THAT DECIDED IT.

        The body has a dozen early returns and the layer fails open, so all but one
        of them log a line and carry on. That is the diagnostic problem this
        wrapper exists for: from outside, a pool whose snapshot expired, a pool
        whose bucket was never configured and a pool whose every host times out on
        the download are the same observable -- jobs that are slower than they
        were, and nothing red anywhere. Each return states its verdict and this
        publishes it, including for the returns a later edit adds.

        It also catches. Invoke-Phase7DependencyCache runs under
        $ErrorActionPreference = 'Stop' inside its own try/catch, and this is
        deliberately a second one: an unexpected throw in the hydrate must cost
        this host its cache, never its registration.
    #>
    [CmdletBinding()]
    param([string] $Master = $script:CacheMaster)
    $verdict = 'error'
    # Started here and not inside the bounded half, so the seconds series covers
    # the same span the Linux one does -- including the throw path, which is the
    # one whose duration nobody can otherwise account for.
    $started = [datetime]::UtcNow
    try {
        $verdict = Invoke-CacheHydrateBounded -Master $Master
    } catch {
        Write-BootLog "phase 7: the cache hydrate failed: $($_.Exception.Message)"
    }
    Write-BootLog "phase 7: cache hydrate verdict: $verdict"
    # After the log line, never instead of it: the log is what an operator reads
    # on a host they are already looking at, and it must not depend on a metric
    # write. Telemetry never throws -- Publish-CacheTelemetry returns $false --
    # but the ordering is the guarantee, not the current implementation.
    $null = Publish-CacheTelemetry -Verdict $verdict `
        -Seconds ([int] ([datetime]::UtcNow).Subtract($started).TotalSeconds)
    return $verdict
}

function Initialize-SlotCache {
    <#
      .SYNOPSIS
        Give slot $Index its own writable cache, seeded from the master.
      .DESCRIPTION
        THE NAMESPACE, NOT THE FLAGS, IS WHAT MAKES THIS SAFE

        host-startup.sh states the rule this follows: root never operates on a
        path inside a directory an untrusted account controls. The Windows layout
        is the same shape as the Linux one --

          C:\ci-cache               SYSTEM + Administrators, slots read-only
          C:\ci\cache               SYSTEM + Administrators -- traversal only
          C:\ci\cache\<idx>         SYSTEM + Administrators -- this function's work area
          C:\ci\cache\<idx>\<tool>  + the slot, Modify -- the writable cache

        -- and it works on Windows for a reason worth writing down, because it
        looks broken at first glance: the slot has NO ACE on C:\ci\cache or on its
        own <idx> directory, yet it opens <idx>\npm perfectly well. Traversal is
        governed by SeChangeNotifyPrivilege ("bypass traverse checking"), which is
        granted to Everyone by default, so a path is reachable when its LAST
        component grants access regardless of the directories above it. That is
        already what makes C:\ci\slots\<idx> work for the workspace, so this is the
        established pattern here rather than a new bet.

        What the layout buys is that a slot cannot create, rename or delete a name
        in <idx>. So it cannot swap the staging directory for a junction between
        the ACL being applied and robocopy writing into it, and it cannot forge
        the .ready marker -- which is why the marker lives in <idx> and not one
        level down where the slot could write it.

        THE MARKER IS CLEARED FIRST AND WRITTEN LAST

        It means "every directory below is present and reachable by this slot",
        not "seeding was attempted". Phase 5 reads it and not the directory,
        because a half-finished seed would otherwise point ten variables at paths
        that are absent or unwritable -- a hard per-job failure rather than the
        cache miss this layer promises.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Index,
        [Parameter(Mandatory = $true)][string] $User,
        [Parameter(Mandatory = $true)][bool] $Seed,
        [datetime] $StartedUtc = [datetime]::UtcNow,
        [string] $Master = $script:CacheMaster
    )

    $dst = Get-SlotCachePath -Index $Index
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Protect-CiDirectory -Path $dst

    $marker = Join-Path $dst '.ready'
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

    # Staging trees from a boot that died mid-copy. Swept here, once, rather than
    # per tool: a stage is only ever published by rename, so anything still
    # wearing the prefix is by definition a copy that never completed.
    #
    # AND EACH ONE IS SCANNED BEFORE IT IS DELETED, for the same reason the
    # retired-slot sweep in Invoke-Phase7DependencyCache is. Only SYSTEM can
    # create the stage DIRECTORY -- $dst is SYSTEM's -- but the stage's CONTENTS
    # carry the slot's Modify grant, because Protect-CiDirectory puts it there
    # before robocopy runs so every copied file inherits it. So a job that ran
    # while a stage was left behind could have planted a junction inside it, and
    # this Remove-Item runs as SYSTEM under Windows PowerShell 5.1, which follows
    # one and deletes what it POINTS AT (PowerShell/PowerShell#621).
    #
    # A stale stage that cannot be shown to be safe is therefore left on disk.
    # It costs disk and is logged; the unique names below mean it can never be
    # mistaken for a stage this boot created, so leaving it is inert.
    foreach ($stale in @(Get-ChildItem -LiteralPath $dst -Filter '.seed-*' -Force -ErrorAction SilentlyContinue)) {
        $inside = @(Get-ChildItem -LiteralPath $stale.FullName -Recurse -Force -ErrorAction SilentlyContinue)
        $staleReason = Get-CacheHostileReason -Entries (@($stale) + $inside)
        if ($staleReason) {
            Write-BootLog ("phase 7: slot $Index -- a stale staging tree is NOT being removed -- " +
                $staleReason)
            continue
        }
        Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($tool in $script:CacheDirs) {
        # THE BUDGET AND THE FLOOR ARE BOTH RE-READ PER TOOL, NOT ONCE PER SLOT.
        #
        # Both quantities move while this loop runs and both were measured before
        # it started. The floor was checked against `Get-CacheMasterSize`, which
        # sums file LENGTH -- not allocated size, not alternate data streams, and
        # robocopy /COPY:DAT copies streams it did not count. A master built to
        # understate itself therefore passes the check and then overruns it, and
        # the volume it fills is the one every OTHER slot's job is running on.
        # Asking the volume again between copies costs one stat and bounds the
        # overrun to a single tool directory: the one that overran does not get
        # published, and the rest of the tools go cold.
        #
        # The budget is the same shape in time. Nine copies per slot, K slots,
        # all before phase 5 registers anything -- see $script:CacheSeedBudgetSeconds.
        if ($Seed) {
            $spent = ([datetime]::UtcNow - $StartedUtc).TotalSeconds
            if (Test-CacheSeedBudgetExpired -ElapsedSeconds $spent `
                    -BudgetSeconds $script:CacheSeedBudgetSeconds) {
                Write-BootLog ("phase 7: slot $Index -- the $([int] $script:CacheSeedBudgetSeconds)s " +
                    "seeding budget is spent after $([int] $spent)s; $tool and everything after it " +
                    'stay cold so this host can register')
                $Seed = $false
            } elseif ((Get-CacheVolumeFreeByte) -lt $script:CacheFreeFloorBytes) {
                Write-BootLog ("phase 7: slot $Index -- the volume is under " +
                    "$([int] ($script:CacheFreeFloorBytes / 1GB)) GB free part-way through the copy; " +
                    "$tool and everything after it stay cold")
                $Seed = $false
            }
        }

        $final = Join-Path $dst $tool
        # Already seeded on an earlier boot: leave it exactly as the slot left it.
        # Re-seeding would delete a warm cache to replace it with a colder one, and
        # the entry cannot have been substituted -- only SYSTEM can create a name
        # in $dst.
        if (Test-Path -LiteralPath $final) { continue }

        # UNIQUE PER ATTEMPT, not the fixed ".seed-$tool" this started as. With a
        # fixed name the delete above it was the only thing standing between a
        # leftover tree and the cache: if it failed -- a transient lock is enough
        # -- robocopy would run against a NON-EMPTY stage, report 2 or 3 (extra
        # files present) which Test-RobocopySuccess correctly reads as success,
        # and the rename would publish the previous attempt's files mixed into
        # this one as a complete cache. A name that cannot collide removes the
        # dependency on that delete succeeding: a stage this loop did not just
        # create is a stage this loop will never publish.
        $stage = Join-Path $dst ('.seed-{0}-{1}' -f $tool, [guid]::NewGuid().ToString('N'))
        $src = Join-Path $Master $tool
        # Not `continue` on a collision: the tail of this loop is what guarantees
        # $final exists at all, and a tool directory that is missing rather than
        # empty fails the job instead of missing the cache.
        if (Test-Path -LiteralPath $stage) {
            Write-BootLog "phase 7: slot $Index -- $stage already exists, $tool stays cold"
        } elseif ($Seed -and (Test-Path -LiteralPath $src)) {
            New-Item -ItemType Directory -Path $stage | Out-Null
            # The ACL goes on BEFORE the copy so every file robocopy writes
            # inherits it. Applying it afterwards would mean walking a tree of
            # hundreds of thousands of small files a second time for no gain.
            Protect-CiDirectory -Path $stage -SlotUser $User

            # /COPY:DAT and NOT /COPYALL: data, attributes and timestamps, but not
            # the SECURITY descriptor. This is the Windows spelling of the Linux
            # `cp -a --no-preserve=ownership` -- the master's ACL is
            # SYSTEM-and-Administrators plus read-only slots, and copying it would
            # hand the slot a cache it cannot write. Omitting S is what lets the
            # inherited ACE from $stage apply instead.
            #
            # /XJ excludes junction points from the copy. The scan in
            # Protect-CacheMaster already refuses the whole master over one, so
            # this is the second line of the same defence, and it is cheap: without
            # it robocopy descends into a junction and copies what it names.
            # Bounded by what is left of the budget, for the reason given in
            # Invoke-BoundedNative: the check above this loop is only asked
            # BETWEEN copies, and one copy that wedges is a host that never
            # registers. A killed robocopy reports -1, which Test-RobocopySuccess
            # already rejects -- that rejection was written for a crashed one and
            # covers this for the same reason.
            $left = Get-CacheSeedSecondsLeft -ElapsedSeconds (([datetime]::UtcNow - $StartedUtc).TotalSeconds) `
                -BudgetSeconds $script:CacheSeedBudgetSeconds
            $copy = Invoke-BoundedNative -FilePath 'robocopy.exe' -TimeoutSeconds $left `
                -ArgumentList @($src, $stage, '/E', '/COPY:DAT', '/XJ', '/R:1', '/W:1',
                    '/NFL', '/NDL', '/NJH', '/NJS', '/NP') `
                -What "robocopy $tool into slot $Index"
            $exit = $copy.ExitCode

            if (Test-RobocopySuccess -ExitCode $exit) {
                # Renamed into place rather than copied into place, because the
                # variables phase 5 writes name the FINAL path: a tool that started
                # while a half-copied tree sat there would read a truncated entry
                # as a real one. Move-Item within one directory on one volume is a
                # rename, so the directory either is not there (a cache miss, which
                # is correct) or is complete.
                Move-Item -LiteralPath $stage -Destination $final
            } else {
                $detail = ''
                if ($copy.Error) { $detail = " -- $($copy.Error)" }
                Write-BootLog "phase 7: slot $Index -- robocopy $tool exited $exit$detail, that cache stays cold"
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Either the master had nothing to give, or the copy failed, or this slot
        # did not fit. All three are a cold cache, which is slow and correct -- but
        # the directory still has to exist and be writable, or the tool pointed at
        # it fails instead of missing.
        if (-not (Test-Path -LiteralPath $final)) {
            New-Item -ItemType Directory -Force -Path $final | Out-Null
            Protect-CiDirectory -Path $final -SlotUser $User
        }
    }

    Set-Content -LiteralPath $marker -Value '' -Encoding Ascii
    return $dst
}

function Invoke-Phase7DependencyCache {
    <#
      .SYNOPSIS
        Seed every slot's dependency cache. Returns index -> cache path.
      .DESCRIPTION
        Fails open in every direction -- see the section header. A slot missing
        from the returned map is a slot phase 5 leaves without cache variables,
        which is the cold-cache behaviour every Windows host has had until now.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][array] $Provisioned)

    $paths = @{}
    $startedUtc = [datetime]::UtcNow
    try {
        # BEFORE THE SCAN AND THE SEAL, AND THAT ORDER IS THE WHOLE DESIGN. The
        # snapshot is untrusted build input; Protect-CacheMaster is the gate that
        # judges the master's contents and then applies an ACL to them. Hydrating
        # afterwards would put content into a tree that had already been judged,
        # already been sealed, and is about to be copied into every slot.
        #
        # Its verdict is not consulted: every one of them, including the ones that
        # mean the master was left exactly as the image baked it, continues into
        # the same scan and the same seal.
        $null = Invoke-CacheHydrate

        $slotUsers = @($Provisioned | ForEach-Object { $_.User })
        if (-not (Protect-CacheMaster -SlotUsers $slotUsers -StartedUtc $startedUtc)) { return $paths }

        New-Item -ItemType Directory -Force -Path $script:CacheSlots | Out-Null
        Protect-CiDirectory -Path $script:CacheSlots

        # Retired indices go before the live ones are seeded. `ci-slots` can be
        # reduced, and a directory for an index above the new count keeps its tree
        # AND its .ready marker -- which says "every tool directory below is
        # present and reachable by this slot". Nothing reads it while the index is
        # retired, so this is hygiene rather than a live bug; it stops being true
        # the moment the count goes back up and the seeding loop finds a directory
        # that already claims to be ready. It is also a full duplicate cache tree
        # per retired slot, on the volume the live ones are sized against.
        #
        # Bounded by what is THERE, not by a guess at the old count: the previous
        # value is recorded nowhere on this host. Only all-digit names are
        # considered, and only ones above the live count are removed -- anything
        # else under C:\ci\cache was not put there by this function.
        foreach ($dir in @(Get-ChildItem -LiteralPath $script:CacheSlots -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($dir.Name -notmatch '^[0-9]+$') { continue }
            if ([int] $dir.Name -le $Provisioned.Count) { continue }
            # SCANNED BEFORE IT IS DELETED, AND THIS IS THE ONE RECURSIVE DELETE
            # ON THIS HOST THAT REACHES A TREE JOB CODE COULD WRITE.
            #
            # `<idx>` is SYSTEM's, but `<idx>\<tool>` carries the slot's Modify
            # grant -- that is the entire point of the layout -- so a job that ran
            # on this host before the count came down could have left a junction
            # in its own cache directory. Windows PowerShell 5.1, which is what
            # runs this file, follows one on `Remove-Item -Recurse` and deletes
            # what it POINTS AT rather than the link (PowerShell/PowerShell#621,
            # fixed in 6.0 and never backported). Aimed at C:\Windows\System32
            # that is a host this pool cannot recover, executed by SYSTEM, from a
            # cleanup path whose whole job is hygiene.
            #
            # So the refusal is to delete at all. A stale cache tree left on disk
            # costs disk and is logged; the other branch costs the machine, and
            # the seeding loop below will not touch a retired index either way.
            $held = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue)
            $reason = Get-CacheHostileReason -Entries (@($dir) + $held)
            if ($reason) {
                Write-BootLog ("phase 7: slot $($dir.Name) retired, but its cache copy is NOT " +
                    "being removed -- $reason")
                continue
            }
            try {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force
                Write-BootLog ("phase 7: slot $($dir.Name) retired (this host now has " +
                    "$($Provisioned.Count)), its cache copy removed")
            } catch {
                Write-BootLog "phase 7: slot $($dir.Name) retired, but its cache copy could not be removed"
            }
        }

        $masterBytes = Get-CacheMasterSize
        foreach ($slot in $Provisioned) {
            # The clock started before the scan and the seal, not here: those are
            # the two tree walks whose cost is set by the image, and a budget that
            # excused them would be measuring the cheap half.

            $free = Get-CacheVolumeFreeByte
            $seed = Test-CacheSeedAffordable -MasterBytes $masterBytes -FreeBytes $free `
                -FloorBytes $script:CacheFreeFloorBytes
            if (-not $seed) {
                Write-BootLog ("phase 7: slot $($slot.Index) -- a $([int] ($masterBytes / 1GB)) GB copy " +
                    "would leave under $([int] ($script:CacheFreeFloorBytes / 1GB)) GB free; it gets empty " +
                    "cache directories and warms from its own jobs instead")
            }
            try {
                $paths[$slot.Index] = Initialize-SlotCache -Index $slot.Index -User $slot.User `
                    -Seed $seed -StartedUtc $startedUtc
            } catch {
                Write-BootLog "phase 7: slot $($slot.Index) -- could not build its cache: $($_.Exception.Message)"
            }
        }
        Write-BootLog ("phase 7: dependency cache seeded for $($paths.Count) slot(s) from " +
            "$script:CacheMaster ($($script:CacheDirs.Count) tool caches, read-only master)")
    } catch {
        Write-BootLog "phase 7: the dependency cache could not be prepared: $($_.Exception.Message)"
    }
    return $paths
}

# --- phase 3: the job credential broker --------------------------------------
#
# WHAT THE BROKER IS FOR, NOW THAT THERE IS NO FENCE
#
# On Linux the fence removes the host identity from job code and the broker hands
# back a weaker one. Section 3A is blunt about what that leaves on Windows: job code can
# reach the metadata server regardless, so a job that wants the host token can
# mint one, and the broker is therefore largely COSMETIC as a boundary. It is
# still built, and the ADR is explicit about why rather than dropping it:
#
#   * it is what makes the reduced identity WORK. `gcloud builds submit` and
#     friends need ADC, the host account has been stripped to
#     serviceAccountTokenCreator on the job account, and the broker is what turns
#     that grant into a credential a job's tooling finds without being rewritten;
#   * a job that mints a host token and impersonates gets exactly what the broker
#     was going to hand it, so the broker costs the attacker nothing and saves
#     every honest workflow a rewrite;
#   * it keeps ONE broker contract across both operating systems. The Python is
#     byte-identical and stays covered by scripts/ci/job-broker.selftest.py.
#
# What it is NOT is a security control on this platform, and this comment exists
# so nobody re-derives one from its presence.
function Install-JobBrokerService {
    <#
      .SYNOPSIS
        Materialise the broker source and run it under the image's shim.
      .DESCRIPTION
        The Python arrives as instance metadata, exactly as the beacon script
        does and exactly as it does on Linux, so one image keeps serving every
        pool while the broker stays versioned with the module. The interpreter and
        the shim do NOT arrive that way: an executable delivered through a channel
        any process on the VM can write is a different kind of thing entirely.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $SourceText,
        [Parameter(Mandatory = $true)][string] $JobServiceAccount,
        [Parameter(Mandatory = $true)][int] $Port
    )

    if (-not (Test-Path -LiteralPath $script:ServiceShim)) {
        Deny-Boot ("the service shim $script:ServiceShim is missing -- this image cannot run the " +
            'job credential broker')
    }
    if (-not (Test-Path -LiteralPath $script:PythonExe)) {
        Deny-Boot ("no interpreter at $script:PythonExe -- this image predates the job credential " +
            'broker, and a pool with a job service account whose jobs get no credentials fails ' +
            'at every deploy step instead of at boot')
    }

    # UTF-8 WITHOUT a BOM. CPython accepts a BOM in a source file, but the broker
    # is byte-identical to the Linux one by design and a Windows-only BOM would
    # make the two copies differ for no reason anybody could later explain.
    [System.IO.File]::WriteAllText($script:BrokerScript, $SourceText,
        (New-Object System.Text.UTF8Encoding($false)))

    # The config, by contrast, is read by the shim -- same encoding as the
    # beacon's, for the same 5.1-decodes-a-BOM-less-file-as-ANSI reason.
    $configPath = Join-Path $script:BinRoot 'ci-job-broker.xml'
    [System.IO.File]::WriteAllText($configPath,
        (Get-BrokerServiceConfig -ScriptPath $script:BrokerScript `
                -JobServiceAccount $JobServiceAccount -Port $Port),
        (New-Object System.Text.UTF8Encoding($true)))

    # The preference is dropped around the native call for the reason given in
    # Install-BeaconService: under Stop, `2>&1` on a native command turns each
    # stderr line into a terminating NativeCommandError, so a shim that merely
    # warns would abort the boot before the exit-code check below ever runs.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $shimOutput = & $script:ServiceShim 'install' $configPath 2>&1
    $shimExit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($shimOutput)) { Write-BootLog "shim: $line" }
    if ($shimExit -ne 0) {
        Deny-Boot "the service shim refused to install the job credential broker (exit $shimExit)"
    }

    Start-Service -Name $script:BrokerServiceName -ErrorAction Stop
    $svc = Get-Service -Name $script:BrokerServiceName -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Deny-Boot "the job credential broker service is '$($svc.Status)', not Running"
    }
}

function Test-JobBrokerReady {
    <#
      .SYNOPSIS
        Does the broker actually VEND a token? Returns $true when it does.
      .DESCRIPTION
        Asserted before any agent registers, because a broker that LOOKS up and
        vends nothing turns every deploy step into a confusing auth failure at job
        time -- the Linux script proves the same thing for the same reason. This
        is the capability, not the daemon: `Get-Service` returning Running is the
        check that passed on the hosts where nothing worked.

        Each attempt is bounded. A broker that ACCEPTS a connection and never
        answers would otherwise turn a 30x2s readiness probe into an unbounded
        wait, which is the 2h55m outage in miniature.

        A vended token proves a broker is THERE, not that it is OURS. The owner
        check after the loop is the second half, and it is deliberately outside
        the retry: a squatter does not go away on attempt 12, and Deny-Boot
        raised inside the `try` would be caught by the very handler that exists
        to tolerate a broker that has not finished starting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Port,
        [int] $Attempts = 30,
        [int] $DelaySeconds = 2
    )
    $uri = "http://127.0.0.1:$Port/computeMetadata/v1/instance/service-accounts/default/token"
    $vended = $false
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $token = Invoke-RestMethod -Uri $uri `
                -Headers @{ 'Metadata-Flavor' = 'Google' } `
                -TimeoutSec $script:HttpTimeoutSeconds
            # A body, not merely a 200. The broker answers 200 with an error
            # document on some paths, and "it responded" is the weaker question.
            if ($token -and $token.access_token) {
                $vended = $true
                break
            }
        } catch {
            $null = $_
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    if (-not $vended) { return $false }

    if (-not (Test-BrokerListenerSid -Sid (Get-PortListenerSid -Port $Port))) {
        Deny-Boot ("something other than LocalSystem is listening on 127.0.0.1:$Port -- refusing " +
            'to point job credentials at a socket this host does not own')
    }
    return $true
}

function Get-PortListenerSid {
    <#
      .SYNOPSIS
        The SID of the process listening on a loopback port, or '' when none is.
      .DESCRIPTION
        Split out from the predicate so the predicate stays pure and testable.
        Returns '' rather than throwing on every failure mode -- no listener, a
        process that exited between the two lookups, a CIM call that did not
        answer -- because Test-BrokerListenerSid treats '' as "not ours", which
        is the fail-closed reading of every one of them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Port)
    try {
        $listener = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)[0]
        if (-not $listener) { return '' }
        $proc = Get-CimInstance -ClassName Win32_Process `
            -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction Stop
        if (-not $proc) { return '' }
        # The SID, not the account name. `NT AUTHORITY\SYSTEM` is localised and
        # this image is only en-US until the day somebody builds one that is not.
        return [string](Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction Stop).Sid
    } catch {
        $null = $_
        return ''
    }
}

function Lock-LoopbackPort {
    <#
      .SYNOPSIS
        Make one TCP port permanently unbindable on this host.
      .DESCRIPTION
        Used for the closed-metadata port, and the reason it is not merely
        cosmetic: with GCE_METADATA_* now always set, a pool with no broker
        points every slot's ADC at 127.0.0.1:1. If a job could BIND that port it
        would be handing the next job on this warm host a token of its own
        choosing -- the no-broker pool would go from "no credentials" to "the
        previous pull request's credentials", which is worse than what this
        change set out to fix.

        Fatal when it fails, because the alternative is a host whose fail-closed
        endpoint is open for anyone to answer on, and the boot log would say
        nothing at all about it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Port)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & netsh @(Get-PortReservationArgument -Port $Port) 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($out)) { Write-BootLog "netsh: $line" }
    # Already reserved is success. The host may have been rebooted, and an
    # excluded port range survives a reboot.
    if ($code -ne 0 -and ($out -join ' ') -notmatch 'already|exists') {
        Deny-Boot ("could not reserve loopback port $Port (netsh exit $code) -- a job could bind " +
            "the endpoint this host's credential-free slots are pointed at")
    }
}

function Invoke-Phase3JobBroker {
    <#
      .SYNOPSIS
        Start the broker, or decide deliberately that this pool has none.
      .DESCRIPTION
        An empty `ci-job-service-account` means no broker and no Google
        credentials for jobs at all. That is a VALID pool -- a repository whose CI
        never touches GCP -- but it is NOT self-enforcing on Windows, and that is
        the correction here. There is no metadata fence (section 3A), so a slot
        whose ADC is unpointed reaches 169.254.169.254 and authenticates as the
        host. The no-broker path therefore has real work to do: it reserves the
        closed loopback port that Get-SlotServiceEnvironment points those slots
        at, so ADC is refused rather than redirected to the host identity.

        Said in the log either way, because "no broker" and "broker that failed"
        must not look the same to whoever reads the boot afterwards.

        Returns the endpoint phase 5 points the slots at, or '' when there is no
        broker -- '' being what Get-SlotServiceEnvironment turns into the closed
        endpoint, which is why it is a return value rather than a flag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $JobServiceAccount,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $BrokerSource,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $BrokerPort
    )

    if ([string]::IsNullOrWhiteSpace($JobServiceAccount)) {
        Lock-LoopbackPort -Port $script:ClosedMetadataPort
        Write-BootLog ('phase 3: no ci-job-service-account -- no broker. Slots are pointed at ' +
            "$script:ClosedMetadataEndpoint, which is reserved and unbindable, so job code gets " +
            'no Google credentials rather than the host identity.')
        return ''
    }

    # Refused, not defaulted. A port that cannot be parsed serves the same broker;
    # an identity that cannot be parsed would be somebody else's.
    $account = $JobServiceAccount.Trim()
    if (-not (Test-JobServiceAccountName -Name $account)) {
        Deny-Boot ('ci-job-service-account is not a service-account address -- refusing to put it ' +
            "in a service definition or a service environment block")
    }

    if ([string]::IsNullOrWhiteSpace($BrokerSource)) {
        Deny-Boot ('a job service account is configured but ci-job-broker-py is empty -- every ' +
            'deploy step on this host would fail at job time with an auth error')
    }

    $port = Get-BrokerPort -Value $BrokerPort
    Install-JobBrokerService -SourceText $BrokerSource -JobServiceAccount $account -Port $port
    if (-not (Test-JobBrokerReady -Port $port)) {
        Deny-Boot ("the job credential broker did not vend a token on 127.0.0.1:$port -- a host " +
            'that registers without it turns every deploy step into a confusing auth failure')
    }

    Write-BootLog "phase 3: job credential broker serving $account on 127.0.0.1:$port"
    return "127.0.0.1:$port"
}

# --- phase 4: the per-job slot reset ------------------------------------------

function Install-JobHook {
    <#
      .SYNOPSIS
        Write both hooks and lock them: every slot may run them, none may edit them.
      .DESCRIPTION
        The ACL is the security half and it is not optional. TWO files are executed
        by every slot on the host, so a slot that could rewrite one would be
        running code in every other slot's identity -- and, the host being warm, in
        every later job's too. This is the Windows spelling of `chown root:root`
        plus `0755`.

        Installed BEFORE any agent registers (phase 5), and fatal if it fails: an
        agent whose JOB_STARTED hook points at a missing file takes work and fails
        all of it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]] $SlotUsers)

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    New-Item -ItemType Directory -Force -Path $script:JobHookRoot | Out-Null
    [System.IO.File]::WriteAllText($script:JobHookStartedPath,
        (Get-JobHookScript -Phase 'Started'), $utf8Bom)
    [System.IO.File]::WriteAllText($script:JobHookCompletedPath,
        (Get-JobHookScript -Phase 'Completed'), $utf8Bom)

    # The directory and the files both. Locking only the files leaves a directory a
    # slot could rename a hook out of, which fails every job rather than
    # subverting one -- but it is the same missing-hook fault by a longer path.
    Protect-CiDirectory -Path $script:JobHookRoot -ReadOnlyUser $SlotUsers
    Protect-CiDirectory -Path $script:JobHookStartedPath -ReadOnlyUser $SlotUsers
    Protect-CiDirectory -Path $script:JobHookCompletedPath -ReadOnlyUser $SlotUsers
    Write-BootLog ("phase 4: reset hooks under $script:JobHookRoot, runnable by " +
        "$($SlotUsers -join ', ') and writable by none of them")
}

function Install-SlotStateDirectory {
    <#
      .SYNOPSIS
        One slot's state directory and its request channel, with the ACLs that ARE
        the privilege split.
      .DESCRIPTION
        Two directories, two different ACLs, and the difference between them is the
        whole boundary this phase rests on:

          <state>\<i>          SYSTEM and Administrators full, the slot READ. The
                               `clean` marker and the verdict live here, so a slot
                               cannot vouch for itself.
          <state>\<i>\request  the same, plus Modify for ci-s<i> alone. This is the
                               only thing a slot may write, and which slot a
                               request names is decided by which of these
                               directories it appeared in.

        Modify rather than a hand-built write-only ACE: a slot must be able to
        create the file and, having created it, it may as well be able to delete
        it -- the service deletes requests anyway, and an ACL nobody can read is an
        ACL nobody maintains. What matters is that the grant does not reach the
        parent, and Protect-CiDirectory disables inheritance on both.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Index)

    $state = Get-SlotStatePath -Index $Index
    $request = Get-SlotRequestPath -Index $Index
    $user = Get-SlotUserName -Index $Index

    New-Item -ItemType Directory -Force -Path $state | Out-Null
    New-Item -ItemType Directory -Force -Path $request | Out-Null
    Protect-CiDirectory -Path $state -ReadOnlyUser @($user)
    Protect-CiDirectory -Path $request -SlotUser $user
    Write-BootLog "phase 4: slot $Index may write $request and read $state, and nothing else"
}

function Install-SlotResetService {
    <#
      .SYNOPSIS
        Install the SYSTEM-side reset service under the shim, and start it.
      .DESCRIPTION
        Fatal when it will not install or start. The alternative is a host whose
        COMPLETED requests pile up unserved: every slot on it fails its next gate,
        which is fail-closed and is also the whole host out of service with the
        reason three log lines away from where anyone would look.

        NOT a per-slot scheduled task, and the ADR records why at length: a task's
        security descriptor is only reachable through
        ITaskFolder.RegisterTaskDefinition, Register-ScheduledTask does not expose
        it, and a mis-set one fails OPEN -- every slot able to run every slot's
        reset, with nothing in the boot log saying so. A directory ACL is the
        boundary phase 1 already establishes and phase 6 already proves, and
        getting it wrong is an Access is denied at the moment of the mistake.

        The payload and its config are written to a directory with NO slot ACE at
        all, unlike the boot probe's: this service runs as LocalSystem, so the
        shim's own log append happens as SYSTEM and there is no slot that needs to
        write beside it.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $script:ServiceShim)) {
        Deny-Boot ("the service shim $script:ServiceShim is missing -- this image cannot reset a " +
            'slot between jobs, and a host that cannot reset a slot must not serve one')
    }

    # UTF-8 WITH a BOM, for the reason Install-BeaconService gives: `-Encoding
    # UTF8` means with-BOM on 5.1 and without-BOM on 7, and a BOM-less file is
    # decoded as ANSI by the 5.1 that runs it.
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    New-Item -ItemType Directory -Force -Path $script:SlotResetRoot | Out-Null
    [System.IO.File]::WriteAllText($script:SlotResetScriptPath, (Get-SlotResetScript), $utf8Bom)
    [System.IO.File]::WriteAllText($script:SlotResetConfigPath,
        (Get-SlotResetServiceConfig -ScriptPath $script:SlotResetScriptPath), $utf8Bom)
    Protect-CiDirectory -Path $script:SlotResetRoot
    Protect-CiDirectory -Path $script:SlotResetScriptPath
    Protect-CiDirectory -Path $script:SlotResetConfigPath

    # The preference is dropped around the native call for the reason given in
    # Install-BeaconService: under Stop, `2>&1` on a native command turns each
    # stderr line into a terminating NativeCommandError before the exit code is read.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $shimOutput = & $script:ServiceShim 'install' $script:SlotResetConfigPath 2>&1
    $shimExit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($shimOutput)) { Write-BootLog "shim: $line" }
    if ($shimExit -ne 0) {
        Deny-Boot "the service shim refused to install the slot reset service (exit $shimExit)"
    }

    try {
        Start-Service -Name $script:SlotResetServiceName -ErrorAction Stop
    } catch {
        Deny-Boot ("the slot reset service would not start ($($_.Exception.Message)) -- no slot on " +
            'this host could be proved clean between jobs')
    }
    Write-BootLog "phase 4: $script:SlotResetServiceName started as LocalSystem"
}

function Save-SlotProfileTemplate {
    <#
      .SYNOPSIS
        Capture one slot's pristine profile, and write the first `clean` marker.
      .DESCRIPTION
        RUNS AFTER PHASE 6 AND BEFORE PHASE 5, AND BOTH HALVES OF THAT ARE LOAD-BEARING

        A Windows profile does not exist until the account logs on, and slot
        accounts are DENIED interactive and network logon by phase 1 -- service
        logon is the only kind they have. So there is nothing to capture until some
        service has run as the slot, and the first one that does is phase 6's boot
        probe. Capturing after it, and before phase 5 hands the account to an agent
        GitHub can dispatch to, is the one window in which the profile exists and
        no job has ever touched it.

        The hive matters, which is why the window matters. HKCU is a persistence
        surface in its own right -- Run keys, HKCU\Environment, an ExecutionPolicy
        -- and NTUSER.DAT is only copyable while the account has no session. The
        probe's service is stopped and removed by the time this runs, so it is.

        Fatal on failure. A slot with no template is a slot the reset service will
        refuse to reset, which is a slot every one of whose jobs fails at the gate.
        Better to deny the boot and say so.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $Index)

    $template = Get-SlotProfileTemplatePath -Index $Index
    $profileDir = ''
    $sid = ''
    try {
        # The SID, resolved from the account name phase 1 created, and then the
        # profile resolved from the SID. Two lookups rather than one because
        # ProfileList is keyed by SID and nothing else, and because a name that no
        # longer resolves is a different fault from a profile that was never made.
        $account = New-Object System.Security.Principal.NTAccount((Get-SlotUserName -Index $Index))
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        $raw = (Get-ItemProperty -LiteralPath $key -Name 'ProfileImagePath').ProfileImagePath
        $profileDir = [System.Environment]::ExpandEnvironmentVariables([string] $raw)
    } catch {
        Deny-Boot ("slot $Index has no profile in the account database " +
            "($($_.Exception.Message)) -- nothing to capture, so nothing could be restored")
    }
    # The account database's answer, checked against the slot it is supposed to
    # describe. A ProfileList entry pointing anywhere else would have this capture
    # -- and every later restore -- reach a directory that is not this slot's.
    if (-not (Test-SlotProfileDirectory -Path $profileDir -Index $Index)) {
        Deny-Boot ("slot $Index resolved to '$profileDir', which is not its profile -- refusing to " +
            'capture a template from it')
    }

    New-Item -ItemType Directory -Force -Path $script:ProfileTemplateRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $template | Out-Null
    # NO slot ACE at all, unlike the hooks: nothing on this host reads a template
    # except SYSTEM, and a slot that could write its own would be handing every
    # later job on that slot whatever it left there.
    Protect-CiDirectory -Path $script:ProfileTemplateRoot
    Protect-CiDirectory -Path $template

    # Bounded, like phase 7's copies and for the identical reason: this runs
    # before phase 5 registers anything, the call operator cannot be asked to give
    # up once the child is running, and a robocopy that wedges here is a host that
    # never registers -- which past the registration grace reads to
    # drain_decision.sh as never-registered, so the pool rebuilds it from the same
    # image forever. A pristine profile is small, so the bound is generous.
    $copy = Invoke-BoundedNative -FilePath 'robocopy.exe' -TimeoutSeconds $script:ProfileTemplateSeconds `
        -What "capturing slot $Index's profile template" -ArgumentList @(
        $profileDir, $template, '/MIR', '/XJ', '/COPY:DAT', '/R:1', '/W:1',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if (-not (Test-RobocopySuccess -ExitCode $copy.ExitCode)) {
        if ($copy.Error) { Write-BootLog "robocopy: $($copy.Error)" }
        Deny-Boot ("could not capture slot $Index's profile template (robocopy exit " +
            "$($copy.ExitCode)) -- every job on this slot would fail at its gate")
    }

    # The first marker, written by the same hand that captured the template. A
    # freshly booted slot IS clean -- nothing has run on it -- and without this its
    # very first job would be failed for a reset that had no predecessor to undo.
    [System.IO.File]::WriteAllText((Get-SlotMarkerPath -Index $Index), 'clean',
        (New-Object System.Text.UTF8Encoding($false)))
    Write-BootLog "phase 4: slot $Index template captured from $profileDir, marked clean"
}

function Invoke-Phase4SlotReset {
    <#
      .SYNOPSIS
        Install the hooks, the state directories and the reset service. Returns
        the two paths phase 5 points the two hook variables at.
      .DESCRIPTION
        UNCONDITIONAL, and that is the whole design decision in this phase. There
        is no `if a job service account is configured` around it: a pool with no
        broker is where an inherited credential is MOST dangerous, because nothing
        on the host competes with whatever a workflow left behind and the leftover
        is simply what the next job authenticates as. The same is true of every
        other thing a job leaves in a profile.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]] $Provisioned)

    $slotUsers = @($Provisioned | ForEach-Object { $_.User })
    Install-JobHook -SlotUsers $slotUsers
    New-Item -ItemType Directory -Force -Path $script:StateRoot | Out-Null
    Protect-CiDirectory -Path $script:StateRoot -ReadOnlyUser $slotUsers
    foreach ($slot in $Provisioned) { Install-SlotStateDirectory -Index $slot.Index }
    Install-SlotResetService
    return @{
        Started   = $script:JobHookStartedPath
        Completed = $script:JobHookCompletedPath
    }
}

function Invoke-Phase4ProfileTemplate {
    <#
      .SYNOPSIS
        Capture every slot's profile template and mark every slot clean.
      .DESCRIPTION
        Separated from Invoke-Phase4SlotReset because the two halves of this phase
        cannot run at the same point in the boot: the hooks and the service must
        exist before any agent registers, and the templates cannot exist until a
        service has logged the slot accounts on. See Save-SlotProfileTemplate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]] $Provisioned)
    foreach ($slot in $Provisioned) { Save-SlotProfileTemplate -Index $slot.Index }
}

# --- phase 5: agent registration as a per-slot service ------------------------

function Wait-RegistrationToken {
    <#
      .SYNOPSIS
        The controller-minted registration token, or a denied boot. Never ''.
      .DESCRIPTION
        CALLED ONCE PER HOST, ABOVE THE SLOT LOOP. See obligation (a) at the top
        of this file: the controller deletes the key as soon as GitHub reports
        ANY of this host's agents registered, so a second read taken after slot 1
        comes up returns nothing and strands slot 2 silently.

        A Windows host cannot mint its own token. Section 3A reduced its service
        account to serviceAccountTokenCreator on the job account and nothing else
        precisely because job code on this platform can reach the metadata server
        and mint whatever the host can -- so the Secret Manager grant the Linux
        host uses to sign its own App JWT is exactly the thing that must not be
        here. The controller mints instead and writes the token to this instance.

        OBLIGATION (b) IS THE TIMEOUT ARM, AND IT IS NOT AN ERROR PATH

        A host that reboots after the key was deleted -- and Windows hosts reboot
        for updates, so this is ordinary -- finds nothing here, and the controller
        will not mint a second: the `<key>-issued` marker it wrote in the same
        metadata call is never removed, and the mint is refused unless that
        marker is provably absent. Blocking is therefore the DESIGNED outcome, not
        a failure to handle one. The host registers nothing, the register-grace
        drain reclaims it, and the MIG replaces it with an instance the controller
        has never issued a token to.

        The alternative -- carrying on with an empty token -- is strictly worse in
        both directions: config.cmd fails with an authentication error that reads
        like a GitHub outage, and if it ever did not, the host would be serving
        jobs the controller believes it deregistered.

        Polled rather than `wait-for-change`d. The long-poll would block until the
        key appears, which on the reboot case above is forever, and forever is the
        2h55m outage: a host that never registers, never powers off, and counts
        against the pool's size the whole time it does not exist.
    #>
    [CmdletBinding()]
    param(
        [int] $TimeoutSeconds = $script:RegistrationWaitSeconds,
        [int] $PollSeconds = $script:RegistrationPollSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $announced = $false
    while ($true) {
        $token = Get-MetadataValue "instance/attributes/$script:RegistrationTokenKey"
        # Trimmed and tested for EMPTY, not for null. An interrupted controller
        # write leaves a zero-length value, and a zero-length token is the case
        # that must block rather than register.
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            Write-BootLog 'phase 5: registration token present'
            return $token.Trim()
        }
        if (-not $announced) {
            Write-BootLog ("phase 5: waiting up to ${TimeoutSeconds}s for the controller to write " +
                "$script:RegistrationTokenKey")
            $announced = $true
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    }

    Deny-Boot ("no $script:RegistrationTokenKey on this instance after ${TimeoutSeconds}s. If this " +
        'host has registered before, this is the EXPECTED transition after a reboot: the ' +
        'controller deleted the key once the agents appeared and will not mint a second one for ' +
        'this instance. Registering with an empty token is refused -- the host registers nothing, ' +
        'the register-grace drain reclaims it, and the MIG replaces it.')
}

function Grant-ServiceLogonAccount {
    <#
      .SYNOPSIS
        Point one service at a slot's local account, without a plaintext password.
      .DESCRIPTION
        THE REASON THIS IS P/INVOKE AND NOT sc.exe OR config.cmd

        Every documented way of setting a service's logon account takes the
        password as a STRING: the sc.exe config form puts it in the process table,
        config.cmd's own logon-password flag does the same, and
        Win32_Service.Change takes a managed String that cannot be
        erased and lives until the GC decides otherwise. On this host the process
        table is readable by the very accounts whose credentials those are, and
        those accounts run pull-request code.

        ChangeServiceConfigW takes the password as a pointer.
        SecureStringToGlobalAllocUnicode marshals it out of the SecureString into
        unmanaged memory, ZeroFreeGlobalAllocUnicode wipes and frees it in a
        `finally`, and no [string] of the password exists at any point. That is
        what keeps the file's standing rule -- the slot password never leaves the
        SecureString it was born in -- true through the one phase that has to
        spend it.

        SERVICE_NO_CHANGE for every field but the account, so this changes the
        logon identity and nothing else about a service config.cmd just wrote.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential] $Credential
    )

    if (-not ('CiHostPool.ServiceConfig' -as [type])) {
        Add-Type -Namespace 'CiHostPool' -Name 'ServiceConfig' -MemberDefinition @'
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr OpenSCManagerW(string machineName, string databaseName, uint access);

[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr OpenServiceW(IntPtr manager, string serviceName, uint access);

[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool ChangeServiceConfigW(IntPtr service, uint serviceType, uint startType,
    uint errorControl, string binaryPath, string loadOrderGroup, IntPtr tagId, string dependencies,
    string startName, IntPtr password, string displayName);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool CloseServiceHandle(IntPtr handle);
'@
    }

    # EVERY NULL STRING HERE IS [NullString]::Value, AND NONE OF THEM MAY BE $null.
    #
    # PowerShell binds $null to a [string] parameter as the EMPTY STRING, not as
    # a null pointer, and this is the one API surface where the difference is
    # fatal. Measured 2026-09-02 on ci-runner-host-win-iit-nn3l, the first
    # Windows host in the fleet ever to reach this phase: OpenSCManagerW($null,
    # $null, ...) arrived as OpenSCManagerW("", "", ...), and an EMPTY database
    # name is not a defaulted one -- the SCM rejects it with win32 123,
    # ERROR_INVALID_NAME, which reads like a path bug and is nothing of the kind.
    # The boot then Deny-Boots, the host registers no agent, and the pool sits at
    # zero slots looking like an image problem.
    #
    # ChangeServiceConfigW is worse than an error, because it SUCCEEDS: NULL
    # means "leave this field alone" and "" means "set this field to empty", so
    # the four $nulls below would have blanked the agent's binary path, load
    # order group, dependencies and display name on the way to setting its logon
    # account. [NullString]::Value is the only value that marshals to a real NULL.
    $nullStr = [NullString]::Value
    $noChange = [uint32]::MaxValue
    $manager = [CiHostPool.ServiceConfig]::OpenSCManagerW($nullStr, $nullStr, 0x0001)
    if ($manager -eq [IntPtr]::Zero) {
        Deny-Boot "cannot open the service control manager (win32 $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    $service = [IntPtr]::Zero
    $password = [IntPtr]::Zero
    try {
        # SERVICE_CHANGE_CONFIG only. Nothing here needs to start, stop or query
        # the service, and a handle that could is a handle a later edit would use.
        $service = [CiHostPool.ServiceConfig]::OpenServiceW($manager, $ServiceName, 0x0002)
        if ($service -eq [IntPtr]::Zero) {
            Deny-Boot ("cannot open service $ServiceName to set its logon account " +
                "(win32 $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))")
        }
        $password = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode(
            $Credential.Password)
        $ok = [CiHostPool.ServiceConfig]::ChangeServiceConfigW($service, $noChange, $noChange,
            $noChange, $nullStr, $nullStr, [IntPtr]::Zero, $nullStr, $Credential.UserName,
            $password, $nullStr)
        if (-not $ok) {
            Deny-Boot ("cannot set $ServiceName to run as $($Credential.UserName) " +
                "(win32 $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())) -- an agent " +
                'left on the SCM default would run every job on this slot as a shared machine account')
        }
    } finally {
        if ($password -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($password)
        }
        if ($service -ne [IntPtr]::Zero) { [CiHostPool.ServiceConfig]::CloseServiceHandle($service) | Out-Null }
        [CiHostPool.ServiceConfig]::CloseServiceHandle($manager) | Out-Null
    }
}

function Write-ServiceEnvironment {
    <#
      .SYNOPSIS
        Write one service's own environment block. Per service, never machine-wide.
      .DESCRIPTION
        A machine-wide TMP hands every slot the same one, which is the collision
        the per-slot directory exists to remove, and machine-wide GCE_METADATA_*
        would point the HOST's own tooling at the broker -- including, on a later
        boot, anything this script runs. The SCM reads `Environment` off the
        service's own key and hands it to that process and nothing else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Environment
    )
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path -LiteralPath $key)) {
        Deny-Boot "no service key at $key -- the runner service was not installed under the name it reported"
    }
    New-ItemProperty -LiteralPath $key -Name 'Environment' `
        -PropertyType MultiString -Force `
        -Value (Get-ServiceEnvironmentValue -Environment $Environment) | Out-Null
}

function Clear-ServiceRecoveryAction {
    <#
      .SYNOPSIS
        Take away the SCM's restart-on-failure policy for one runner service.
      .DESCRIPTION
        THIS IS THE WINDOWS SPELLING OF THE LINUX UNIT'S `Restart=no`, AND THE
        README'S RECYCLE CONTRACT DEPENDS ON IT.

        Agents here are not --ephemeral, so the controller drains a host by
        DEREGISTERING its agents through the GitHub API -- which GitHub refuses
        while an agent is executing a job, and which is exactly what makes a
        cordoned host lose its idle slots permanently while its working slot
        finishes. A deregistered slot must STAY deregistered.

        A service installed by config.cmd carries the SCM's recovery actions. An
        agent that auto-restarts after a job-time failure re-registers itself,
        takes more work, and does it on a host the controller believes is draining
        -- so the host that was supposed to be retiring never retires, and the
        pool holds a machine nobody can delete. A cleanly exiting agent is not a
        "failure" and should not trigger recovery at all; the guarantee this
        design needs is not "should not".

        `reset= 0 actions= ""` is empty-string-terminated on sc.exe's own command
        line, and Windows PowerShell 5.1 DROPS an empty argument when it builds a
        native command line -- so `& sc.exe ... 'actions=' ''` would send
        `actions=` with nothing after it and sc.exe would reject the whole call.
        Handing cmd.exe one string is what keeps the empty argument. $ServiceName
        is safe to interpolate only because Get-RunnerServiceName refused anything
        that was not literally `actions.runner.<...>`, and it came out of a file
        the slot account can write.

        AgentName is mandatory rather than optional on purpose. Get-RunnerServiceName
        validates shape AND ownership, and ownership is the half that stops this
        slot's recovery policy being cleared off a SIBLING slot's already-running
        service. A default would make the re-check here weaker than the one the
        caller already passed, which is the opposite of what a second check is for.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][string] $AgentName
    )

    if ((Get-RunnerServiceName -Marker $ServiceName -AgentName $AgentName) -ne $ServiceName) {
        Deny-Boot "refusing to pass '$ServiceName' to sc.exe -- it is not a runner service name"
    }

    # The preference is dropped around the native call for the reason given in
    # Install-BeaconService: under Stop, `2>&1` on a native command turns each
    # stderr line into a terminating NativeCommandError before the exit code is
    # ever read.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & cmd.exe /c "sc.exe failure `"$ServiceName`" reset= 0 actions= `"`"" 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($output)) { Write-BootLog "sc: $line" }
    if ($exit -ne 0) {
        Deny-Boot ("could not clear the recovery actions on $ServiceName (exit $exit) -- an agent " +
            'that restarts itself out of a cordon re-registers, takes more work, and keeps a host ' +
            'the controller is draining alive forever')
    }
}

function Register-SlotAgent {
    <#
      .SYNOPSIS
        Configure and start one slot's agent as a service running as that slot.
      .DESCRIPTION
        The order is the safety property, again, and every step is fatal:

          1. copy the baked agent, per slot. config.cmd writes `.runner` and
             `.credentials` into the directory it runs in, so K agents sharing one
             directory would share one identity;
          2. config.cmd, ELEVATED. It creates a service and touches an account
             right, so it cannot run as the slot -- which is why step 4 exists;
          3. read the service name the agent itself recorded, and refuse anything
             that is not one, or that is not THIS slot's;
          4. STOP it. config.cmd --runasservice starts the service it installs,
             under the SCM default account, before this script has said anything
             about identity -- and neither the logon account nor the environment
             block reaches a process that is already running;
          5. re-apply the ACL. config.cmd wrote `.runner` and `.credentials` as
             the elevated identity, so without this the agent cannot read its own
             credentials -- or, worse, a sibling can. The Linux script's
             `chown -R "$u:$u" "$dir"` is the same step;
          6. environment, then recovery actions, then the logon account -- all
             while it is stopped. A service started once with the SCM's default
             account has already written its own state as the wrong identity;
          7. start, and verify it is Running rather than assume it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Slot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RegistrationToken,
        [Parameter(Mandatory = $true)][string] $Owner,
        [Parameter(Mandatory = $true)][string] $Repo,
        [Parameter(Mandatory = $true)][string] $InstanceName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Labels,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RunnerGroup,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Environment
    )

    # OBLIGATION (b), AT THE LAST POSSIBLE MOMENT. Wait-RegistrationToken already
    # denies the boot rather than returning empty, so reaching here with nothing
    # means a later edit made the token optional somewhere in between. config.cmd
    # with an empty --token produces an agent-side authentication failure that
    # reads like a GitHub outage; blocking produces a host the register-grace
    # drain reclaims, which is the designed outcome.
    if ([string]::IsNullOrWhiteSpace($RegistrationToken)) {
        Deny-Boot ("slot $($Slot.Index): refusing to run config.cmd with an empty registration " +
            'token -- a host that cannot register must block and be reclaimed, not register wrong')
    }

    if (-not (Test-Path -LiteralPath $script:RunnerTemplate)) {
        Deny-Boot ("no agent at $script:RunnerTemplate -- this image predates the runner and a host " +
            'that installed one at boot would have re-invented the per-job cost this pool removes')
    }

    $dir = Get-SlotWorkspacePath -Index $Slot.Index
    $agent = Join-Path $dir 'runner'
    $name = Get-SlotAgentName -InstanceName $InstanceName -Index $Slot.Index
    New-Item -ItemType Directory -Force -Path $agent | Out-Null
    Copy-Item -Path (Join-Path $script:RunnerTemplate '*') -Destination $agent -Recurse -Force

    $configArgs = Get-RunnerConfigArgument -Owner $Owner -Repo $Repo -Name $name `
        -Labels $Labels -WorkPath (Join-Path $agent '_work') -RunnerGroup $RunnerGroup

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # The token is appended HERE and nowhere a test or a log can reach it. It is
    # still an argument to config.cmd and therefore visible in this host's process
    # table for the length of that call -- accepted, because section 3A already
    # accepts that job code on this host can read the same value straight out of
    # instance metadata, and the controller's delete is what bounds both.
    $configOutput = & (Join-Path $agent 'config.cmd') @configArgs --token $RegistrationToken 2>&1
    $configExit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    # Redacted, and not because config.cmd is known to echo it. It is not, today.
    # The log sink is SYSTEM-and-Administrators-only and the serial console is
    # behind project IAM, so this is the third lock on a door that is already
    # shut -- and the one that does not depend on upstream never changing its
    # error text.
    foreach ($line in @($configOutput)) {
        Write-BootLog ("slot $($Slot.Index) config: " +
            (Get-RedactedLine -Line ([string] $line) -Secret $RegistrationToken))
    }
    if ($configExit -ne 0) {
        Deny-Boot "slot $($Slot.Index): config.cmd failed (exit $configExit)"
    }

    $marker = ''
    $markerPath = Join-Path $agent '.service'
    if (Test-Path -LiteralPath $markerPath) {
        $marker = Get-Content -Raw -LiteralPath $markerPath
    }
    $serviceName = Get-RunnerServiceName -Marker $marker -AgentName $name
    if (-not $serviceName) {
        Deny-Boot ("slot $($Slot.Index): the agent did not record a usable service name for $name in " +
            "$markerPath -- its environment, its logon account and its recovery policy would all " +
            'be set on a service that does not exist or belongs to another slot, while the one that ' +
            'does starts with none of them')
    }

    # RECORDED WHERE THE SLOT CANNOT REACH IT, for phase 4's reset service.
    #
    # `.service` above lives inside the slot's own runner directory, which the slot
    # account can write, and the name inside it reaches Stop-Service running as
    # SYSTEM. Get-RunnerServiceName has just validated it twice -- shape, and
    # ownership by this slot's agent name -- so what is copied here is the
    # validated result into a directory phase 4 locked to SYSTEM and
    # Administrators. The reset service reads this and never the agent's copy.
    [System.IO.File]::WriteAllText((Get-SlotRunnerServicePath -Index $Slot.Index), $serviceName,
        (New-Object System.Text.UTF8Encoding($false)))

    # THE STEP WITHOUT WHICH EVERY STEP BELOW IT IS DECORATION
    #
    # `config.cmd --runasservice` does not just install the service, it STARTS
    # it -- under the SCM default account, before this script has said a word
    # about identity. ChangeServiceConfigW edits the registry, not a running
    # process, and the SCM reads `Environment` at start; so a service left
    # running here keeps the shared machine account and none of the environment
    # block for its whole life, while `Start-Service` on an already-running
    # service returns success and the Running check below agrees. The agent would
    # take pull-request jobs as the wrong identity with no hooks, and every log
    # line would say it worked.
    #
    # Inline rather than a helper, because the helper would be named
    # Stop-Something and the analyzer demands a ShouldProcess block on that verb.
    $installed = Get-Service -Name $serviceName -ErrorAction Stop
    if ($installed.Status -ne 'Stopped') {
        Write-BootLog ("slot $($Slot.Index): $serviceName came up under the SCM default account " +
            'during config.cmd -- stopping it before its identity and environment are set')
        Stop-Service -Name $serviceName -Force -ErrorAction Stop
        # WaitForStatus THROWS on expiry rather than returning with a stale status,
        # so without the catch the one failure this block exists to report is the
        # one it reports worst: a raw System.ServiceProcess.TimeoutException instead
        # of the sentence saying what it means for the host. It still fails closed
        # either way -- the catch is for whoever reads the boot log afterwards.
        try {
            $installed.WaitForStatus('Stopped', [timespan]::FromSeconds($script:ServiceStopSeconds))
        } catch {
            Deny-Boot ("slot $($Slot.Index): $serviceName did not stop within " +
                "$($script:ServiceStopSeconds)s ($($_.Exception.Message))")
        }
        $installed.Refresh()
        if ($installed.Status -ne 'Stopped') {
            Deny-Boot ("slot $($Slot.Index): $serviceName will not stop, so it would keep the shared " +
                'machine account and none of the per-slot environment for the life of this host')
        }
    }

    # After config.cmd, and re-proved rather than assumed. `.runner` and
    # `.credentials` were written by the elevated identity; an agent that cannot
    # read its own credentials never comes up, and a sibling that can read them is
    # the boundary this whole design is built on.
    Protect-CiDirectory -Path $agent -SlotUser $Slot.User

    Write-ServiceEnvironment -ServiceName $serviceName -Environment $Environment
    Clear-ServiceRecoveryAction -ServiceName $serviceName -AgentName $name
    Grant-ServiceLogonAccount -ServiceName $serviceName -Credential $Slot.Credential

    Start-Service -Name $serviceName -ErrorAction Stop
    $svc = Get-Service -Name $serviceName -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Deny-Boot "slot $($Slot.Index): $serviceName is '$($svc.Status)', not Running"
    }

    # Running is not the assertion. WHO it is running as is. Everything above
    # this line is an attempt to make the answer be the slot account, and the
    # failure this file spent the most care on -- an agent that quietly kept the
    # SCM default -- looks exactly like success from the Status alone.
    $configured = (Get-CimInstance -ClassName Win32_Service `
            -Filter "Name='$serviceName'" -ErrorAction Stop).StartName
    if (-not (Test-ServiceLogonAccount -StartName $configured -SlotUser $Slot.User)) {
        Deny-Boot ("slot $($Slot.Index): $serviceName is running as '$configured', not $($Slot.User) " +
            '-- every job on this slot would run as a machine-wide account shared with the other slots')
    }
    Write-BootLog ("phase 5: slot $($Slot.Index) registered as $name, service $serviceName " +
        "running as $configured, recovery actions cleared")
}

function Stop-RunnerService {
    <#
      .SYNOPSIS
        Stop every runner service on this host. Reports; returns nothing.
      .DESCRIPTION
        THE CONTAINMENT THE DENY ON ITS OWN DOES NOT PROVIDE. Called only from
        Wait-RegistrationTokenRemoved, on the one failure in this script that
        happens AFTER the agents are already serving.

        Stopped, not deregistered. GitHub does not dispatch to an offline runner,
        so no further job reaches this host either way, and the two differ in
        what the controller then sees. host_facts() in controller-startup.sh
        counts this host's runners by NAME and not by status, so a stopped agent
        still reads `present` -- which keeps the host out of drain_decision's
        `never-registered` arm, where it does not belong, and lets it fall
        through to the ordinary idle rule with busy=0. Deregistering instead
        would drop it to `absent`, and an `absent` host past the register grace
        is drained as a FAILED BOOT, which is a worse diagnosis than the true
        one and loses the agents' own logs with it.

        Matched by the `actions.runner.*` prefix rather than by re-deriving each
        slot's service name. The names are built per slot inside Register-Slot-
        Agent from a marker file and are not carried out of it; the prefix is
        GitHub's own scheme and nothing else on this image uses it. Nothing here
        reaches sc.exe, so Get-RunnerServiceName's refusal -- which exists to
        keep an underived name out of a command line -- is not the relevant
        guard. A zero count is LOGGED and not swallowed: it means the
        containment did not happen and only the visibility is left.

        Returns nothing on purpose, and the count is logged from in here rather
        than handed back. Write-BootLog is uncapturable by construction now (see
        the note at it, and has_uncapturable_boot_log), so this is no longer the
        difference between working and not -- but a function that reports its
        own outcome does not depend on that remaining true.
    #>
    # THE PATTERN IS CONSTRAINED, and the parameter is only injectable at all so a
    # test can drive it. Stop-Service -Force stops DEPENDENTS as well, so a widened
    # pattern here does not merely stop too many services -- a bare `*` would take
    # the beacon and the job broker down with the agents, and the beacon is what
    # the controller reads to decide this host is alive. Nothing attacker-influenced
    # reaches this today; the validation is what keeps that from being a property of
    # the current call sites rather than of the function.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [ValidatePattern('^actions\.runner\.[A-Za-z0-9._*-]+$')]
        [string] $NamePattern = 'actions.runner.*'
    )

    $stopped = 0
    foreach ($svc in @(Get-Service -Name $NamePattern -ErrorAction SilentlyContinue)) {
        if (-not $PSCmdlet.ShouldProcess($svc.Name, 'Stop-Service')) { continue }
        try {
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            $stopped = $stopped + 1
            Write-BootLog "phase 5: stopped $($svc.Name)"
        } catch {
            Write-BootLog "phase 5: could not stop $($svc.Name) ($($_.Exception.Message))"
        }
    }
    if ($stopped -eq 0) {
        Write-BootLog ("phase 5: NO runner service matched $NamePattern, so nothing was contained " +
            '-- this host may still be able to take a job')
    }
}

function Wait-RegistrationTokenRemoved {
    <#
      .SYNOPSIS
        Witness that the registration token is gone from this instance's metadata.
      .DESCRIPTION
        THE THIRD BULLET OF SECTION 3A, AND THE ONE PR 5 SHIPPED WITHOUT

        The controller deletes `ci-registration-token` the moment GitHub reports
        any of this host's agents registered. Nothing on the host proves it did.
        A key left behind is a LIVE repository registration token sitting in
        instance metadata, which section 3A says outright is readable by anything
        holding this machine's identity -- and by the time this runs, the things
        holding this machine's identity include pull-request code in a slot. A
        job that reads it can register an agent of its own into the repository.

        Polled to a jittered bound, not read once, because the delete rides the
        controller's tick and a single read taken here would fail on a perfectly
        healthy fleet. The jitter is explained at the constant and is load-
        bearing: one controller is the shared dependency of every host booting
        at the same time.

        WHY THE DENY IS NOT ENOUGH ON ITS OWN, AND WHAT IS DONE ABOUT IT

        Every OTHER Deny-Boot in this script fires before the agents exist, so
        the host reads reg=absent at the controller and drain_decision's
        `never-registered` arm reclaims it past the register grace. Deny-Boot's
        own docstring says so, and for those callers it is true.

        IT IS NOT TRUE HERE, and assuming it was would be the expensive mistake.
        By the time this runs the agents have registered, so the host reads
        `present`, not `absent`, and that arm is never entered. recycle_decision
        does not help either: it refuses anything whose instance template is not
        `stale`, and registration state is not one of its triggers. A bare throw
        here would leave a host in the pool, taking jobs, with a live
        registration token in its metadata and a FATAL line nobody is reading.

        So the runner services are STOPPED first, and that is the actual
        containment: GitHub dispatches nothing to an offline runner, the host
        goes idle at busy=0, and drain_decision's ordinary idle rule retires it
        once idle passes the grace window. See Stop-RunnerService for why they
        are stopped rather than deregistered.

        Its one honest gap: drain_decision keeps a host at the floor
        unconditionally (`keep:at-floor`), so on a pool sitting at min_hosts this
        machine is not retired and occupies a floor slot until an operator or a
        template change moves it. That is a capacity fault and not an exposure --
        it takes no jobs in that state -- and it is the reason the deny stays,
        because the FATAL line is what tells the operator which host to look at.
    #>
    [CmdletBinding()]
    param(
        [int] $TimeoutSeconds = (Get-JitteredTimeout -BaseSeconds $script:TokenRemovalWaitSeconds `
                -JitterSeconds $script:TokenRemovalJitterSeconds -Roll (Get-Random -Minimum 0.0 -Maximum 1.0)),
        [int] $PollSeconds = $script:RegistrationPollSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if ([string]::IsNullOrWhiteSpace((Get-MetadataValue "instance/attributes/$script:RegistrationTokenKey"))) {
            Write-BootLog "phase 5: $script:RegistrationTokenKey is gone from this instance's metadata"
            return
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    }

    # BEFORE the throw, because the throw does not do this and the drain rules
    # will not either -- a host whose agents registered never reads `absent`.
    Stop-RunnerService

    Deny-Boot ("$script:RegistrationTokenKey is STILL on this instance ${TimeoutSeconds}s after its " +
        'agents registered. That value is a live repository registration token, readable by any ' +
        'job on this host, and the controller was supposed to have deleted it. The token is not ' +
        'removed by this -- the host cannot delete its own metadata -- but the runner services are ' +
        'stopped above, so no further job can land here, and the host goes idle and is drained.')
}

function Invoke-Phase5Registration {
    <#
      .SYNOPSIS
        Register every slot's agent from ONE read of the registration token.
      .DESCRIPTION
        OBLIGATION (a) IS THE SHAPE OF THIS FUNCTION, NOT A CHECK INSIDE IT

        The read is above the loop and its value is passed down. Moving it into
        Register-SlotAgent -- which is the tidier-looking edit, since that is
        where the token is used -- breaks a two-slot host in a way nothing on the
        controller can see: slot 1 registers, GitHub reports the host `partial`,
        the controller deletes the key, and slot 2's read comes back empty. The
        host runs at half capacity and every log line says success. The bash
        self-test asserts the read's position for exactly this reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array] $Provisioned,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Config,
        # The two hook paths phase 4 installed, as a dictionary rather than one
        # string: the two ends of a job do different work, and a single path here
        # would be a signature that cannot express the difference.
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $HookPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $BrokerEndpoint,
        # Index -> cache path, from phase 7. A slot that is absent from it gets no
        # cache variables at all, which is the cold-cache behaviour every Windows
        # host had before issue #150 closed.
        [System.Collections.IDictionary] $CachePaths = @{}
    )

    $regToken = Wait-RegistrationToken
    foreach ($slot in $Provisioned) {
        $cache = ''
        if ($CachePaths.Contains($slot.Index)) { $cache = [string] $CachePaths[$slot.Index] }
        $block = Get-SlotServiceEnvironment -Index $slot.Index `
            -StartedHookPath ([string] $HookPath.Started) `
            -CompletedHookPath ([string] $HookPath.Completed) `
            -BrokerEndpoint $BrokerEndpoint -CachePath $cache `
            -HostLabel $Config.HostLabel
        Register-SlotAgent -Slot $slot -RegistrationToken $regToken `
            -Owner $Config.Owner -Repo $Config.Repo -InstanceName $Config.InstanceName `
            -Labels $Config.Labels -RunnerGroup $Config.RunnerGroup -Environment $block
    }
    Write-BootLog "phase 5: $($Provisioned.Count) agent(s) registered"

    # Section 3A's third bullet. The token this phase spent must be gone from the
    # metadata it was spent from, and the host is the only thing in a position to
    # look. See Wait-RegistrationTokenRemoved for why the failure is fatal.
    Wait-RegistrationTokenRemoved
}

# --- phase 6: the boot probe, the harness -------------------------------------
#
# WHY THE PAYLOAD RUNS AS A SERVICE AND NOT AS A PROCESS
#
# The claim phase 6 makes is about what a SLOT ACCOUNT can do, so the payload has
# to run as one, and Windows has no `sudo -u`. Every ordinary way of starting a
# process as another local account takes the password as a managed String --
# Start-Process -Credential, `runas`, `schtasks /RP` -- and this file has a
# standing rule that the slot password never leaves the SecureString it was born
# in, because the accounts whose credentials those are run pull-request code and
# can read this host's process table.
#
# Phase 5 already owns the one mechanism that honours that rule:
# ChangeServiceConfigW, which takes the password as a pointer to unmanaged memory
# that is zeroed in a `finally`. So the probe is installed as a service by the
# image's shim, repointed at the slot account by the same Grant-ServiceLogonAccount
# phase 5 uses, started once, and deleted. The FIRST slot account, not a
# purpose-made one: a job runs as a slot account, and a probe run as anything
# else measures something no job ever is.

function Protect-ProbeVerdictFile {
    <#
      .SYNOPSIS
        Create an empty, freshly-ACLed verdict file for exactly one slot to write.
      .DESCRIPTION
        TWO HOLES, AND THIS CLOSES BOTH.

        The first is the ACL. The verdict decides whether this host registers, and
        it is written by an unprivileged account; a file every slot could write is
        a file any job on a multi-slot host could pre-answer. SYSTEM and
        Administrators keep FullControl, the PROBING slot gets Modify, and no
        other principal gets anything -- the same shape phase 1 gives a slot
        workspace, applied to one file.

        The second is freshness, and it is the one a stale-file check does not
        close. The host reboots; a verdict from the previous boot is a real file
        with real, possibly passing, content, and "the file is old" is a judgement
        the harness would have to make from a timestamp the writer controls. So
        the file is REMOVED and re-created empty here, before the service exists,
        and a removal that does not take denies the boot. Anything read afterwards
        was written by the probe this boot started, or the read finds the empty
        file and Get-ProbeFailure reports no verdict at all.

        The file sits directly in C:\ci, which the slot has no rights on at all.
        That is deliberate and it works: Windows grants SeChangeNotifyPrivilege --
        bypass traverse checking -- to Everyone by default, so a full path opens
        against the file's own ACL without any right on the directories above it.
        The slot can write this one file and cannot enumerate the directory
        holding it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $SlotUser)

    Remove-Item -LiteralPath $script:ProbeResultPath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ProbeResultPath) {
        Deny-Boot ("could not remove a pre-existing $script:ProbeResultPath -- this boot could not " +
            'tell a verdict its own probe wrote from one left by an earlier boot, and reading the ' +
            'wrong one is the silent pass phase 6 exists to prevent')
    }
    New-Item -ItemType File -Path $script:ProbeResultPath -Force | Out-Null
    Protect-CiDirectory -Path $script:ProbeResultPath -SlotUser $SlotUser
    Write-BootLog "phase 6: $script:ProbeResultPath is empty and writable by $SlotUser alone"
}

function Install-BootProbeService {
    <#
      .SYNOPSIS
        Install the probe under the shim and repoint it at the slot account.
      .DESCRIPTION
        The payload and the shim config are written to C:\ci\boot-probe, whose ACL
        is the awkward part and is explained at the constant: the directory has to
        be slot-WRITABLE because the shim writes its own log beside the config it
        was handed and its append path does not catch an access denial, so a
        read-only directory is a service that fails inside OnStart with no verdict
        and no explanation. The two files are then re-locked to read-and-execute
        individually, which is the phase-4 hook shape.

        A service that will not start is FATAL here rather than left to the
        verdict wait. Both roads end in Deny-Boot, but only this one names the
        actual fault; the other reports "no verdict at all" three minutes later.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScriptText,
        [Parameter(Mandatory = $true)][string] $SlotUser,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential] $Credential
    )

    if (-not (Test-Path -LiteralPath $script:ServiceShim)) {
        Deny-Boot ("the service shim $script:ServiceShim is missing -- this image cannot run the " +
            'boot probe, and a host that registers without proving the slot boundary has proved nothing')
    }

    # UTF-8 WITH a BOM, for the reason Install-BeaconService gives: `-Encoding
    # UTF8` means with-BOM on 5.1 and without-BOM on 7, and a BOM-less file is
    # decoded as ANSI by the 5.1 that runs it.
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    New-Item -ItemType Directory -Force -Path $script:ProbeRoot | Out-Null
    [System.IO.File]::WriteAllText($script:ProbeScriptPath, $ScriptText, $utf8Bom)
    [System.IO.File]::WriteAllText($script:ProbeConfigPath,
        (Get-ProbeServiceConfig -ScriptPath $script:ProbeScriptPath), $utf8Bom)

    Protect-CiDirectory -Path $script:ProbeRoot -SlotUser $SlotUser
    Protect-CiDirectory -Path $script:ProbeScriptPath -ReadOnlyUser @($SlotUser)
    Protect-CiDirectory -Path $script:ProbeConfigPath -ReadOnlyUser @($SlotUser)

    # AND THE BINARY THAT READS THEM, which is the one that was missed. The
    # service's binPath is the shim itself, and phase 1 locks C:\ci, C:\ci\bin
    # and C:\ci\slots to SYSTEM and Administrators with inheritance disabled --
    # so ci-service-shim.exe carries no ACE for any slot. Repointing the service
    # at the slot and starting it would make the SCM launch an image that token
    # may neither read nor execute: ERROR_ACCESS_DENIED, a 1053 start failure,
    # and a Deny-Boot on every host in the pool. Read-and-execute only, never
    # Modify: a slot able to WRITE this file would own the beacon and the broker,
    # which the SCM re-executes as LocalSystem on the next reboot.
    #
    # THIS RELIES ON BYPASS-TRAVERSE-CHECKING, and it is stated because it is the
    # kind of default a hardened image removes. C:\ci and C:\ci\bin remain
    # SYSTEM-and-Administrators-only, so a file-level ACE is reachable at all
    # only because Windows grants SeChangeNotifyPrivilege to Everyone by default:
    # a full path opens against the file's own ACL without any right on the
    # directories above it. An image that revokes that privilege breaks this the
    # same way it breaks the verdict file in C:\ci -- closed, as a service that
    # will not start, not as a probe that quietly passes.
    #
    # Reverted by Revoke-ProbeSlotAccess once the verdict is in, so the "no slot
    # ACE under C:\ci" invariant is true of the host phase 5 runs on.
    Protect-CiDirectory -Path $script:ServiceShim -ReadOnlyUser @($SlotUser)

    # The preference is dropped around the native call for the reason given in
    # Install-BeaconService: under Stop, `2>&1` on a native command turns each
    # stderr line into a terminating NativeCommandError before the exit code is read.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $shimOutput = & $script:ServiceShim 'install' $script:ProbeConfigPath 2>&1
    $shimExit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($shimOutput)) { Write-BootLog "shim: $line" }
    if ($shimExit -ne 0) {
        Deny-Boot "the service shim refused to install the boot probe (exit $shimExit)"
    }

    # UNVERIFIED. No real Windows host has booted this path yet: the shim
    # installs every other service in this file as LocalSystem and has never been
    # asked to run as an unprivileged local account, and nothing in CI can boot a
    # GCE Windows instance to find out. The specific things not yet observed are
    # that the shim's own log append succeeds from C:\ci\boot-probe as the slot,
    # that the SCM accepts the account here given the SeServiceLogonRight phase 1
    # granted, and that the SCM's load of ci-service-shim.exe under the slot
    # token succeeds on the file-level ACE granted above -- which is to say that
    # bypass-traverse-checking is still granted to Everyone on this image. All
    # three fail CLOSED if the guess is wrong -- a service that
    # will not start denies the boot below, and one that starts and writes
    # nothing denies it at the verdict wait -- so the failure mode of being wrong
    # is a Windows pool that refuses to serve, not one that serves unproved.
    Grant-ServiceLogonAccount -ServiceName $script:ProbeServiceName -Credential $Credential

    try {
        Start-Service -Name $script:ProbeServiceName -ErrorAction Stop
    } catch {
        Deny-Boot ("the boot probe service would not start as $SlotUser " +
            "($($_.Exception.Message)) -- nothing on this host has proved the slot boundary")
    }
    Write-BootLog "phase 6: $script:ProbeServiceName started as $SlotUser"
}

function Wait-ProbeVerdict {
    <#
      .SYNOPSIS
        The parsed verdict, or $null when none arrived in time.
      .DESCRIPTION
        Returns $null rather than throwing, because $null is a value
        Get-ProbeFailure already knows how to read -- it is the loudest finding
        it has -- and one decision point is better than two.

        Both an unreadable file and an unparseable one keep waiting rather than
        failing: the verdict is written by another process and this can catch it
        mid-write, at which point ConvertFrom-Json throws on a truncated
        document. Bounded, so a payload that never finishes becomes a missing
        verdict instead of a hung boot.

        NOTHING IS LOGGED FROM IN HERE, and that is not an oversight. This
        function's value IS its verdict and the caller branches on $null, so it
        emits the verdict and nothing else; the timeout is reported by the
        caller. Write-BootLog no longer writes to the success stream, so this is
        belt as well as braces -- but the belt is the one being relied on.
    #>
    [CmdletBinding()]
    param(
        [int] $TimeoutSeconds = $script:ProbeWaitSeconds,
        [int] $PollSeconds = $script:ProbePollSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $raw = ''
        try {
            $raw = [string] (Get-Content -Raw -LiteralPath $script:ProbeResultPath -ErrorAction Stop)
        } catch {
            $null = $_
        }
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                return (ConvertFrom-Json -InputObject $raw)
            } catch {
                $null = $_
            }
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    }
    return $null
}

function Clear-BootProbeService {
    <#
      .SYNOPSIS
        Stop and delete the transient probe service. Never fatal.
      .DESCRIPTION
        The shim has no `delete` verb, so `sc.exe delete` is the removal. A
        cleanup failure is LOGGED and not fatal, and that asymmetry is deliberate:
        the verdict has already been reached by the time this runs, and denying a
        boot whose probe passed because a service could not be deleted would trade
        a proved host for none. The service is Manual and non-restarting
        (Get-ProbeServiceConfig), so one left behind runs nothing.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Service -Name $script:ProbeServiceName -ErrorAction SilentlyContinue)) { return }
    Stop-Service -Name $script:ProbeServiceName -Force -ErrorAction SilentlyContinue

    # ABSOLUTE PATH, not a bare `sc.exe`. This process is LocalSystem and a bare
    # name is resolved by CreateProcess's search order; SystemPaths.Tool in
    # ci-service-shim.cs states the rule for the same reason and this was the one
    # call in phase 6 that did not follow it. No hijackable directory is KNOWN to
    # sit earlier in that order -- the point is not to rebut a known hijack but to
    # stop the absence of one from having to be re-proved after every change to
    # PATH, to the app-paths registry, or to the image's directory ACLs.
    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & $sc delete $script:ProbeServiceName 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    foreach ($line in @($output)) { Write-BootLog "sc: $line" }
    if ($exit -ne 0) {
        Write-BootLog "phase 6: could not delete $script:ProbeServiceName (exit $exit)"
    }
}

function Revoke-ProbeSlotAccess {
    <#
      .SYNOPSIS
        Take back every ACE phase 6 granted a slot. Fatal if one does not revert.
      .DESCRIPTION
        THE INVARIANT IS "NO SLOT ACE ANYWHERE UNDER C:\ci", AND THIS IS WHAT
        MAKES IT LITERALLY TRUE RATHER THAN TRUE BY ARGUMENT.

        Phase 6 hands the probing slot three grants it does not need afterwards:
        Modify on C:\ci\boot-probe (the shim appends its log there), Modify on
        C:\ci\boot-probe.json (the slot writes the verdict), and ReadAndExecute
        on the shim binary (the SCM loads it under the slot token). Phase 5 then
        registers agents as that same account, so from that point on the holder
        of these ACEs is pull-request code. No exploit route through them was
        found -- the shim grant is read-only, and nothing re-executes the two
        boot-probe paths -- but "we looked and found nothing" is a claim about
        today's file layout, and the next writer under C:\ci does not get to
        inherit it silently.

        Reverting is the SAME call with no -SlotUser: Protect-CiDirectory
        rewrites the whole ACL from scratch every time, so there is no ACE to
        remove by hand and no ordering to get wrong.

        FATAL, unlike Clear-BootProbeService, and the asymmetry is the point. A
        service left installed runs nothing -- it is Manual and non-restarting.
        An ACE left behind is a standing grant to the account phase 5 is about to
        start job code as, and this is the last moment anything checks. Set-Acl
        as SYSTEM on a file SYSTEM owns does not fail for benign reasons, so a
        failure here is a fact about the host worth refusing to boot over.
    #>
    [CmdletBinding()]
    param()

    foreach ($path in @($script:ProbeRoot, $script:ProbeResultPath, $script:ServiceShim)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            Protect-CiDirectory -Path $path
        } catch {
            Deny-Boot ("could not take the boot probe's grant on $path back off the slot account " +
                "($($_.Exception.Message)) -- phase 5 is about to run pull-request code as that " +
                'account and this was the last thing standing between the two')
        }
    }
    Write-BootLog 'phase 6: the probing slot no longer holds any grant under C:\ci'
}

function Invoke-Phase6BootProbe {
    <#
      .SYNOPSIS
        Prove the slot boundary from a slot's own context, or deny the boot.
      .DESCRIPTION
        RUNS BEFORE PHASE 5, and that is the whole point of the phase. A host that
        proves its identity is not worthless must never accept a job, and an agent
        registered first is an agent GitHub can hand work to while the proof is
        still running.

        EVERY failure path ends in Deny-Boot, including the two that look like
        absence rather than failure: a service that would not start, and a verdict
        that never arrived. A probe that silently no-ops is worse than no probe --
        it converts an unproved host into a host with a phase-6 line in its boot
        log saying nothing went wrong.

        The one thing that is NOT fatal is deleting the service afterwards. See
        Clear-BootProbeService.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array] $Provisioned,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Config,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string] $BrokerEndpoint
    )

    if ($Provisioned.Count -lt 1) {
        Deny-Boot 'phase 6 has no slot account to run the boot probe as, so the slot boundary is unproved'
    }
    if ([string]::IsNullOrWhiteSpace($Config.AppKeySecret)) {
        # Both capability checks live behind the same guard in the payload, so an
        # empty secret name does not degrade the probe to half a proof -- it
        # removes the proof and leaves two blank statuses that Get-ProbeFailure
        # would then report as two mysteries. Name the real fault here instead.
        Deny-Boot ('phase 6 has no App-key secret name, so the probe cannot ask whether this host ' +
            'can still read it, and the demand-metric check is gated on the same value')
    }

    $slot = $Provisioned[0]
    Write-BootLog "phase 6: proving the slot boundary as $($slot.User)"

    $payload = ''
    try {
        $payload = Get-ProbeScript `
            -SecretName $Config.AppKeySecret `
            -JobServiceAccount $Config.JobSa `
            -BrokerEndpoint $BrokerEndpoint `
            -SiblingWorkspace (Get-ProbeSiblingWorkspace -Index $slot.Index -SlotCount $Provisioned.Count) `
            -CacheRoot (Get-SlotWorkspacePath -Index $slot.Index)
    } catch {
        # Test-ProbeLiteral throws rather than sanitizes, and the throw is the
        # finding: a metadata value that is not a bare literal would have been
        # interpolated as code into a payload holding a live host token.
        Deny-Boot "the boot probe payload could not be built: $($_.Exception.Message)"
    }

    Protect-ProbeVerdictFile -SlotUser $slot.User

    $verdict = $null
    try {
        Install-BootProbeService -ScriptText $payload -SlotUser $slot.User -Credential $slot.Credential
        $verdict = Wait-ProbeVerdict
    } finally {
        Clear-BootProbeService
        # AFTER the stop-and-delete, never before: the service is still loading
        # the shim image and writing the verdict until Clear-BootProbeService
        # returns, so revoking first would race the measurement this phase
        # exists to take. In the finally rather than at the end of the function
        # because Install-BootProbeService's own Deny-Boot paths pass through
        # here too, and a denied boot is exactly when nobody is coming back to
        # tidy up.
        Revoke-ProbeSlotAccess
    }
    if ($null -eq $verdict) {
        Write-BootLog "phase 6: no verdict at $script:ProbeResultPath after $script:ProbeWaitSeconds s"
    }

    $findings = @(Get-ProbeFailure -Result $verdict -JobServiceAccount $Config.JobSa `
            -ExpectedIdentity $slot.User)
    foreach ($finding in $findings) { Write-BootLog "phase 6: FINDING -- $finding" }
    if ($findings.Count -gt 0) {
        Deny-Boot ("the boot probe found $($findings.Count) reason(s) this host must not take a " +
            'job: ' + ($findings -join '; '))
    }
    Write-BootLog 'phase 6: slot boundary proved from a slot context'
}

function Invoke-Main {
    [CmdletBinding()]
    param()
    $cfg = Invoke-Phase0Preflight

    # One slot is the fallback, not an error. `ci-slots` is written by Terraform
    # and the Windows pool pins it to 1; a host that arrived without it is still a
    # host, and refusing the boot over a missing count would trade a working
    # single-slot machine for none.
    $slots = 1
    if ($cfg.Slots -match '^[0-9]+$' -and [int] $cfg.Slots -ge 1) { $slots = [int] $cfg.Slots }
    $provisioned = @(Invoke-Phase1SlotSetup -Slots $slots)
    $slotUsers = @($provisioned | ForEach-Object { $_.User })

    # Named, not counted. Phase 5 registers one agent per account listed here, so
    # a boot log that says "3 slots" and a host that has ci-s1 and ci-s3 read the
    # same -- and the difference is which agent never came back.
    Write-BootLog ('phase 1: slot accounts ' + ($slotUsers -join ', '))

    # Both before phase 5, and that ordering is the same safety property the rest
    # of this file is built on: an agent registered before its broker turns every
    # deploy step into an auth failure, and an agent registered before its hook
    # takes work whose JOB_STARTED points at a file that is not there.
    $brokerEndpoint = Invoke-Phase3JobBroker `
        -JobServiceAccount $cfg.JobSa -BrokerSource $cfg.BrokerSource -BrokerPort $cfg.BrokerPort
    $hookPath = Invoke-Phase4SlotReset -Provisioned $provisioned

    # AFTER phase 1 because it needs the slot accounts to seal the master against,
    # and BEFORE phase 5 because phase 5 is what writes the variables that point a
    # job at the result. Its position relative to phases 3, 4 and 6 does not
    # matter: it touches no credential and proves no boundary. It is placed here
    # rather than last because it is the only phase that can take minutes, and a
    # slot registered before its cache exists would take a job that runs cold
    # while the copy it was meant to use is still landing.
    $cachePaths = Invoke-Phase7DependencyCache -Provisioned $provisioned

    # BEFORE PHASE 5, and the ordering is the safety property. The probe spends a
    # slot credential to prove the boundary; phase 5 spends it on agents GitHub
    # can hand a job to immediately. Proving second proves nothing.
    Invoke-Phase6BootProbe -Provisioned $provisioned -Config $cfg -BrokerEndpoint $brokerEndpoint

    # THE SECOND HALF OF PHASE 4, AND IT CAN ONLY RUN HERE.
    #
    # A Windows profile does not exist until the account logs on, and phase 1
    # denies these accounts every logon type except service -- so the first
    # profile on this host is the one phase 6's probe service just created. This
    # is the single window in which every slot has a profile and no job has ever
    # run in one: after the probe, before the agents. See Save-SlotProfileTemplate.
    Invoke-Phase4ProfileTemplate -Provisioned $provisioned

    # LAST, and the only phase that makes this host reachable by a job. Everything
    # above it is a boundary; this is what is let inside one.
    Invoke-Phase5Registration -Provisioned $provisioned -Config $cfg `
        -HookPath $hookPath -BrokerEndpoint $brokerEndpoint -CachePaths $cachePaths
}

# Dot-sourceable without side effects, so Pester can import the pure functions
# above on ubuntu-latest. A requirement of the design, not a style preference,
# and asserted by a test rather than trusted.
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Invoke-Main
}
