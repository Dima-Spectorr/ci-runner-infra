#!/usr/bin/env bash
# Self-test for the OS axis in ci-runner-host-pool's Terraform.
#
# docs/adr-windows-pool.md §6, PR "the OS axis in Terraform", asks for exactly
# this gate: that with `host_os` unset the rendered boot-script key is the one
# every existing pool renders today, and that each refusal §1 and §3A name is
# REACHABLE — a precondition nothing can trip is not a precondition.
#
# WHY A TEXT GATE AND NOT `terraform validate`
#
# `terraform validate` does not evaluate variable validation or resource
# preconditions: both are PLAN-time, and a plan needs credentials and a project
# this repository's CI does not have. identity-split.selftest.sh exists for the
# same reason and against the same wall. So the properties that make the
# plan-time guards reachable at all are asserted statically here.
#
# WHAT THIS FILE GUARDS THAT NOTHING ELSE CAN
#
#   the boot-script key      A Windows instance carrying `startup-script`, or a
#                            Linux one carrying `windows-startup-script-ps1`,
#                            runs NO boot script: the guest agent looks only for
#                            the key belonging to its own platform. The host
#                            comes up healthy, registers zero agents, is drained
#                            at register_grace_seconds as a failed boot, is
#                            rebuilt from the same template, and the pool churns
#                            hosts at full price forever while every metric
#                            reads "hosts running". Nothing in the boot script
#                            can catch this, because the boot script is what did
#                            not run. §1, "What host_os actually switches".
#
#   the Linux key set        Every Windows-only key is merged in under the
#                            conditional. Written unconditionally with an empty
#                            value instead, each one is a diff on every existing
#                            pool in the fleet and a key the Linux boot script
#                            has never seen.
#
#   the refusals             Each one is the ONLY plan-time notice a consumer
#                            gets before a mistake becomes a churning MIG or, in
#                            the registration-token case, a pull request holding
#                            the GitHub App private key. A weakened condition
#                            still applies clean, which is the whole problem.

# Every predicate below matches the TEXT of the module, in which `${...}`,
# `$deadline` and friends are literal characters. Expanding them here would
# compare against this test's own environment and pass on any module at all —
# so the single quotes are the point.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL="$HERE/../../modules/ci-runner-host-pool"
MAIN="$POOL/main.tf"
VARS="$POOL/variables.tf"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# A grep against a MISSING file is false, and false lands in whichever branch a
# check happens to use — so a renamed module would turn some of these green
# rather than red. Assert the inputs exist before asserting anything about them.
for f in "$MAIN" "$VARS"; do
  [ -r "$f" ] || { echo "FAIL: missing $f — every check below would be vacuous"; exit 1; }
done

# Code only: full-line comments stripped, so prose ABOUT a refusal can never
# satisfy the check FOR the refusal. HCL line comments are `#`, the same
# character bash uses, so the helper transfers unchanged from its siblings.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# Never `... | grep -q` under `set -o pipefail`. `grep -q` exits the moment it
# matches, the writer upstream takes SIGPIPE and exits 141, and pipefail then
# makes the PIPELINE fail — so a successful match is reported as a failure. It
# is a race with how much the writer had already buffered, which is why that
# artefact passed on a laptop and failed on a runner against a byte-identical
# file. Every predicate below matches against a string, not through a pipe.
matches() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  [ "${n:-0}" -gt 0 ]
}

count_of() { # <text> <ere>
  local n
  n=$(printf '%s\n' "$1" | grep -cE -- "$2")
  printf '%s' "${n:-0}"
}

# --- invariant 1: host_os exists, defaults to linux, and is constrained ------

has_host_os_variable() { # <variables.tf>
  local code
  code=$(code_of "$1")

  matches "$code" '^variable "host_os" \{' || return 1

  # The default is the entire no-op guarantee for the fleet that exists today.
  # A pool that does not mention host_os must plan as a Linux pool, or seven
  # pools change identity, boot key and refusal set on their next apply.
  matches "$code" '^  default     = "linux"$' || return 1

  # Constrained to the two values, in the shape ci-runner-identity's own host_os
  # uses. Without it a typo — "Windows", "win" — renders the LINUX boot key on a
  # pool the operator believes is Windows, which is the silent churn loop.
  matches "$code" 'contains\(\["linux", "windows"\], var\.host_os\)' || return 1

  # The Windows image floor travels with the OS. Absent, the boot script falls
  # back to 1 and a host boots from an image predating what the script assumes.
  matches "$code" '^variable "windows_image_min_version" \{' || return 1
}

# --- invariant 2: the boot-script key is selected by OS ----------------------

has_os_selected_boot_key() { # <main.tf>
  local code
  code=$(code_of "$1")

  # One local, one conditional, two keys. The Windows key is spelled
  # `windows-startup-script-ps1` and nothing else: the guest agent matches the
  # key name exactly and silently ignores every other.
  matches "$code" '^  boot_script_metadata = var\.host_os == "windows" \? \{' || return 1
  matches "$code" '^    "windows-startup-script-ps1" = local\.windows_host_startup$' || return 1
  matches "$code" '^    "startup-script" = local\.host_startup$' || return 1

  # …carrying the real script, not a placeholder — and carrying it through the
  # wrapper, because the raw text is 140% of a metadata value (see invariant 9).
  matches "$code" 'windows_host_startup_source = file\("\$\{path\.module\}/scripts/windows-host-startup\.ps1"\)' || return 1
  matches "$code" 'windows_host_startup = templatefile\("\$\{path\.module\}/scripts/windows-boot-wrapper\.ps1", \{' || return 1

  # …and actually rendered. A local nothing merges into the template is a
  # rename away from being deleted as unused, and the template would keep
  # whatever key it had.
  matches "$code" '^  metadata = merge\(local\.boot_script_metadata, local\.windows_host_metadata, \{' || return 1

  # Exactly one Linux boot key in the file, and it is the conditional's. The
  # hardcoded `startup-script = local.host_startup` this change replaced would
  # otherwise sit in the merged map and win on a Windows pool.
  [ "$(count_of "$code" '"startup-script" = local\.host_startup')" -eq 1 ] || return 1
  ! matches "$code" '^    startup-script = local\.host_startup$' || return 1
}

# --- invariant 3: the host and the controller are TOLD their OS --------------

has_host_os_metadata() { # <main.tf>
  local code
  code=$(code_of "$1")

  # Twice: once on the host template, where the boot script asserts it against
  # the platform it is actually running on, and once on the controller, which
  # chooses a liveness gate by it. Both read a value; neither infers an OS from
  # the absence of a key, which is how a mis-wired pool gets a confident wrong
  # answer instead of a refusal.
  [ "$(count_of "$code" '^    "ci-host-os" +=  *var\.host_os$')" -eq 2 ] || return 1
}

# --- invariant 4: a Linux pool renders the key set it renders today ----------

has_unchanged_linux_key_set() { # <main.tf>
  local code block key

  code=$(code_of "$1")
  # The conditional's own body, start to `} : {}`. Everything Windows-only must
  # live inside it.
  block=$(awk '/^  windows_host_metadata = var\.host_os == "windows" \? \{$/,/^  \} : \{\}$/' "$1")

  matches "$code" '^  windows_host_metadata = var\.host_os == "windows" \? \{$' || return 1

  for key in 'enable-guest-attributes' 'ci-beacon-script' 'ci-image-min-version'; do
    # Present in the conditional …
    matches "$block" "\"$key\"" || return 1
    # … and NOWHERE else. One occurrence, and the occurrence is that one. A
    # second copy written with an empty value on linux is a diff on every pool
    # in the fleet and a key the Linux boot script has never seen.
    [ "$(count_of "$code" "^ +\"$key\" +=")" -eq 1 ] || return 1
  done

  # The beacon needs the namespace turned on: guest attributes are off by
  # default, and the host's first write failing is a refusal to register for a
  # reason no boot log names.
  matches "$block" '"enable-guest-attributes" = "TRUE"' || return 1
}

# --- invariant 5: the image pairing, in both directions ----------------------

has_image_pairing_refusal() { # <main.tf>
  local code
  code=$(code_of "$1")

  # `ci-runner-host-win` CONTAINS the Linux family as a substring, so the two
  # tests cannot be independent: the Windows one runs first and the Linux one is
  # its complement. Written independently, every Windows image scores as both
  # and the Windows refusal fires on the correct image.
  matches "$code" 'image_names_windows_family += *can\(regex\("ci-runner-host-win", var\.image\)\)' || return 1
  matches "$code" 'image_names_linux_family += *can\(regex\("ci-runner-host", var\.image\)\) && !local\.image_names_windows_family' || return 1

  # Both directions refused. The copy-paste error is a consumer duplicating the
  # Linux module block and forgetting the image; the reverse costs the same.
  matches "$code" 'var\.host_os != "windows" \|\| !local\.image_names_linux_family' || return 1
  matches "$code" 'var\.host_os != "linux" \|\| !local\.image_names_windows_family' || return 1

  # …and both messages say what the mispairing DOES. "wrong image family" reads
  # as a naming quibble; the actual consequence is a host that runs no boot
  # script, registers nothing, and is rebuilt from the same template forever.
  [ "$(count_of "$code" 'no boot script at all')" -eq 2 ] || return 1
}

# --- invariant 6: the inputs a Windows pool must not be given ----------------

has_windows_input_refusals() { # <main.tf>
  local code
  code=$(code_of "$1")

  # Nothing on a Windows host reads the registry list — no container runtime, no
  # credential helper, no docker config. Accepted, it applies clean and fails
  # inside a job as an unauthenticated pull.
  matches "$code" 'var\.host_os != "windows" \|\| length\(var\.extra_registry_hosts\) == 0' || return 1

  # A preemption takes every slot on a host whose boot costs minutes, and the
  # Windows licence is per vCPU-hour whatever the provisioning model.
  matches "$code" 'var\.host_os != "windows" \|\| !var\.spot' || return 1

  # 600s is calibrated to a Linux boot plus K x config.sh. A Windows first boot
  # plus K account creations plus K x `config.cmd --runasservice` does not fit,
  # and not fitting IS the churn loop this input exists to prevent.
  matches "$code" 'var\.host_os != "windows" \|\| var\.register_grace_seconds >= 1200' || return 1

  # Windows plus toolchains plus warm cache plus K workspaces plus a pagefile. A
  # host that fills its disk mid-job fails every slot at once and reports it as
  # a repository problem.
  matches "$code" 'var\.host_os != "windows" \|\| var\.boot_disk_size_gb >= 200' || return 1
}

# --- invariant 7: the §3A refusal, which is the security one -----------------

has_controller_minted_token_refusal() { # <main.tf>
  local code
  code=$(code_of "$1")

  # A Windows host account holds no Secret Manager grant, because job code on a
  # Windows host can mint a token for whatever that account is (§3A: there is no
  # fence and no mechanism to build one). So a Windows pool whose host mints its
  # own registration token is BOTH the broken configuration and the unsafe one —
  # and the unsafe one is the one that happens to work today, which is exactly
  # why it has to be refused deliberately rather than left to fail.
  matches "$code" 'var\.host_os != "windows" \|\| var\.controller_mints_registration_token' || return 1
  matches "$code" 'GitHub App private key' || return 1
}

# --- invariant 8: every refusal is still there -------------------------------

has_every_windows_refusal() { # <main.tf>
  local code
  code=$(code_of "$1")

  # Five §1 refusals (image, registry hosts, spot, register grace, boot disk)
  # plus §3A's registration-token declaration = six conditions guarded on
  # windows, plus the one guarded on linux. A count is what notices a refusal
  # deleted wholesale, which no per-refusal predicate above can distinguish from
  # a refusal that was never written.
  [ "$(count_of "$code" 'var\.host_os != "windows" \|\|')" -eq 6 ] || return 1
  [ "$(count_of "$code" 'var\.host_os != "linux" \|\|')" -eq 1 ] || return 1

  # And every one of them says why it matters. A precondition whose message is
  # the condition restated sends the consumer back to the module source.
  #
  # `host_os = \"` and not a bare `host_os`: main.tf has other preconditions
  # that mention var.host_os in passing -- the network-tag budget names it to
  # say how many shared-infra tags a Linux pool adds -- and counting those made
  # the total survive a refusal message being gutted. The seven messages under
  # test all quote the OS they refuse, which is exactly the part a restated
  # condition loses.
  [ "$(count_of "$code" '^      error_message = ".*host_os = \\"')" -ge 6 ] || return 1
}

# --- invariant 9: the Windows boot script travels compressed -----------------

windows_boot_script_is_compressed() { # <main.tf>
  local code wrapper
  code=$(code_of "$1")

  # 366,591 characters of PowerShell against the 262,144 a metadata value holds.
  # The Linux side crossed the same line at 106% and cost three repositories a
  # day of CI; Windows is at 140% and has never been applied anywhere, so it has
  # never said so. Whoever first turns a Windows pool on gets an Error 413 at
  # CREATE time on a plan that read clean — after "the boot script metadata bug
  # was fixed" is already in the history, which is what makes it read as new.
  matches "$code" '^  windows_host_startup_gz += base64gzip\(local\.windows_host_startup_source\)' || return 1
  matches "$code" 'windows_host_startup = templatefile\("\$\{path\.module\}/scripts/windows-boot-wrapper\.ps1", \{' || return 1
  matches "$code" '^    gz = local\.windows_host_startup_gz$' || return 1

  # The raw source must not be what reaches metadata. This is the revert that
  # plans clean and 413s.
  ! matches "$code" '^    "windows-startup-script-ps1" = local\.windows_host_startup_source$' || return 1

  # The cap is asserted for BOTH arms, not just the one that has been applied.
  matches "$code" 'length\(local\.boot_script_metadata\[var\.host_os == "windows" \? "windows-startup-script-ps1" : "startup-script"\]\) < 262144' || return 1

  # And the wrapper itself has the two properties that decide whether a failed
  # unpack is a drained host or a host serving nothing: it refuses an empty
  # decode explicitly — a `catch` only ever sees a decode that FAILED — and it
  # unpacks under C:\ci, never C:\Windows\Temp, where a slot user on a warm
  # host's reboot could replace the file SYSTEM is about to run.
  wrapper=$(cat "$HERE/../../modules/ci-runner-host-pool/scripts/windows-boot-wrapper.ps1")
  matches "$wrapper" 'IsNullOrWhiteSpace\(\$plain\)' || return 1
  matches "$wrapper" '^\$root = .C:\\ci.$' || return 1
  ! matches "$wrapper" '\$env:TEMP' || return 1
  matches "$wrapper" 'S-1-5-18' || return 1
  matches "$wrapper" 'S-1-5-32-544' || return 1
}

# --- the helper carries the trap it was written to avoid ---------------------
# A match on the FIRST line of a large input is the worst case: with `grep -q`
# the writer is still pushing bytes when grep exits on the match, takes SIGPIPE,
# and pipefail reports the successful match as a failure.
if matches "$(seq 1 20000)" '^1$' && ! matches "$(seq 1 20000)" '^abc$'; then
  ok
else
  bad "matches() is unreliable on a large input — the pipefail/SIGPIPE trap is back, and every predicate below is now untrustworthy"
fi

# --- the real module must satisfy every one ----------------------------------

if has_host_os_variable "$VARS"; then
  ok
else
  bad "host_os is missing, unconstrained, or no longer defaults to linux — an unconstrained typo renders the LINUX boot key on a pool its operator believes is Windows, and a changed default re-plans every existing pool in the fleet as something else"
fi

if has_os_selected_boot_key "$MAIN"; then
  ok
else
  bad "the boot-script metadata key is not selected by host_os — a Windows instance carrying startup-script runs NO boot script at all, comes up healthy, registers nothing, is drained at the register grace and rebuilt from the same template forever while every metric reads 'hosts running'"
fi

if has_host_os_metadata "$MAIN"; then
  ok
else
  bad "ci-host-os is not published to both the host and the controller — the boot script then cannot assert which platform it was delivered to, and the controller has to infer an OS from an absent key rather than read one"
fi

if has_unchanged_linux_key_set "$MAIN"; then
  ok
else
  bad "a Windows-only metadata key escaped the conditional — every existing Linux pool then gets a key its boot script has never seen, and the module stops being byte-identical for a consumer that never mentioned host_os"
fi

if has_image_pairing_refusal "$MAIN"; then
  ok
else
  bad "the image/OS pairing is unchecked or checked with independent tests — ci-runner-host-win contains the Linux family as a substring, so independent tests score every Windows image as both and refuse the correct one"
fi

if has_windows_input_refusals "$MAIN"; then
  ok
else
  bad "a Windows pool can be planned with an input that is meaningless or unsafe on it — extra_registry_hosts nothing reads, spot that takes every slot with it, a register grace calibrated to a Linux boot, or a disk that fills mid-job and fails every slot at once"
fi

if has_controller_minted_token_refusal "$MAIN"; then
  ok
else
  bad "a Windows pool can be planned without controller-minted registration — that pool's host account keeps the Secret Manager grant, and job code on a Windows host can mint a token for it, so the first pull-request job holds the GitHub App private key"
fi

if has_every_windows_refusal "$MAIN"; then
  ok
else
  bad "a plan-time refusal was removed — a Windows pool then applies clean into the failure the refusal existed to name, hours before anything else notices"
fi

if windows_boot_script_is_compressed "$MAIN"; then
  ok
else
  bad "the Windows boot script no longer travels gzipped in its wrapper — at 366,591 characters it is 140% of the 262,144 a GCE metadata value holds, so the first Windows pool applies into an Error 413 at create time on a plan that read clean, which is exactly how three repositories lost a day of CI on the Linux side"
fi

# --- mutation cases: prove the checks above can actually fail -----------------
#
# Every one reverts a property in place and asserts the covered predicate
# changes its answer. A detector that has not been SEEN to fire is not a
# detector: this repository shipped a `describe --filter` past 51 green checks
# because a stub accepted a flag real gcloud rejects.
mutate() { # <description> <file> <sed-program> <predicate> — predicate goes false
  local desc="$1" file="$2" prog="$3" pred="$4" tmp
  tmp=$(mktemp)
  sed "$prog" "$file" >"$tmp"
  # A sed program that matches NOTHING leaves the predicate true and reads as a
  # detected mutation only because the file was never mutated. That is the same
  # class of hole as the `describe --filter` stub: a green check over an
  # assertion that was never made. Refuse to score a case that changed nothing.
  if cmp -s "$tmp" "$file"; then
    bad "mutation changed nothing, so it asserts nothing: $desc"
    rm -f "$tmp"
    return
  fi
  if "$pred" "$tmp"; then
    bad "mutation not detected: $desc"
  else
    ok
  fi
  rm -f "$tmp"
}

# 1. The variable stops protecting the fleet that exists today.
mutate "host_os defaulting to windows" "$VARS" \
  's|^  default     = "linux"$|  default     = "windows"|' \
  has_host_os_variable
mutate "the two-value constraint dropped" "$VARS" \
  's|contains(\["linux", "windows"\], var.host_os)|var.host_os != ""|' \
  has_host_os_variable
mutate "the Windows image floor variable removed" "$VARS" \
  's|^variable "windows_image_min_version" {|variable "win_image_floor" {|' \
  has_host_os_variable

# 2. The boot-script key: the silent-churn mistake, in each shape it takes.
mutate "the Windows pool given the Linux boot key" "$MAIN" \
  's|"windows-startup-script-ps1" = local.windows_host_startup|"startup-script" = local.windows_host_startup|' \
  has_os_selected_boot_key
mutate "the selection reverted to a hardcoded key" "$MAIN" \
  's|^  boot_script_metadata = var.host_os == "windows" ? {|  boot_script_metadata = {|' \
  has_os_selected_boot_key
mutate "the selected key never merged into the template" "$MAIN" \
  's|^  metadata = merge(local.boot_script_metadata, local.windows_host_metadata, {|  metadata = merge(local.windows_host_metadata, {|' \
  has_os_selected_boot_key
mutate "the hardcoded Linux key left in the merged map as well" "$MAIN" \
  's|^    "ci-host-os" = var.host_os$|    startup-script = local.host_startup|' \
  has_os_selected_boot_key

# 3. The OS stops being stated.
mutate "ci-host-os pinned to a literal instead of the variable" "$MAIN" \
  's|^    "ci-host-os" = var.host_os$|    "ci-host-os" = "linux"|' \
  has_host_os_metadata
mutate "the controller no longer told which OS its hosts run" "$MAIN" \
  's|^    "ci-host-os"                 = var.host_os$||' \
  has_host_os_metadata

# 4. A Windows-only key escapes onto every Linux pool.
mutate "guest attributes enabled unconditionally" "$MAIN" \
  's|^    "ci-host-os" = var.host_os$|    "enable-guest-attributes" = "TRUE"|' \
  has_unchanged_linux_key_set
mutate "the beacon script written on every pool" "$MAIN" \
  's|^    "ci-host-os" = var.host_os$|    "ci-beacon-script" = ""|' \
  has_unchanged_linux_key_set
mutate "the conditional dropped, making the whole block unconditional" "$MAIN" \
  's|^  windows_host_metadata = var.host_os == "windows" ? {$|  windows_host_metadata = {|' \
  has_unchanged_linux_key_set

# 5. The image pairing weakens.
mutate "the two family tests made independent" "$MAIN" \
  's@ && !local.image_names_windows_family@@' \
  has_image_pairing_refusal
mutate "the Windows family test loosened to the Linux family" "$MAIN" \
  's|can(regex("ci-runner-host-win", var.image))|can(regex("ci-runner-host", var.image))|' \
  has_image_pairing_refusal
mutate "the reverse pairing no longer refused" "$MAIN" \
  's@var.host_os != "linux" || !local.image_names_windows_family@true@' \
  has_image_pairing_refusal
mutate "the messages reduced to naming the wrong family" "$MAIN" \
  's@no boot script at all@the wrong image@g' \
  has_image_pairing_refusal

# 6. A refused input becomes acceptable again.
mutate "extra_registry_hosts accepted and ignored on windows" "$MAIN" \
  's@var.host_os != "windows" || length(var.extra_registry_hosts) == 0@true@' \
  has_windows_input_refusals
mutate "spot allowed on windows" "$MAIN" \
  's@var.host_os != "windows" || !var.spot@true@' \
  has_windows_input_refusals
mutate "the register grace floor dropped back to the Linux default" "$MAIN" \
  's|var.register_grace_seconds >= 1200|var.register_grace_seconds >= 600|' \
  has_windows_input_refusals
mutate "the boot disk floor removed" "$MAIN" \
  's@var.host_os != "windows" || var.boot_disk_size_gb >= 200@true@' \
  has_windows_input_refusals

# 7. The security refusal.
mutate "controller-minted registration no longer required on windows" "$MAIN" \
  's@var.host_os != "windows" || var.controller_mints_registration_token@true@' \
  has_controller_minted_token_refusal
mutate "the message no longer naming what is at stake" "$MAIN" \
  's|GitHub App private key|App key|' \
  has_controller_minted_token_refusal

# 8. A refusal deleted wholesale rather than weakened.
mutate "one windows refusal removed entirely" "$MAIN" \
  's@var.host_os != "windows" || var.boot_disk_size_gb >= 200@var.boot_disk_size_gb >= 200@' \
  has_every_windows_refusal
mutate "the linux-side refusal removed entirely" "$MAIN" \
  's@var.host_os != "linux" || !local.image_names_windows_family@!local.image_names_windows_family@' \
  has_every_windows_refusal
mutate "a refusal message that only restates its condition" "$MAIN" \
  's|^      error_message = "host_os|      error_message = "invalid input: host-os|' \
  has_every_windows_refusal

# 9. The Windows boot script goes back to travelling raw, in each shape.
mutate "the raw Windows script back on the metadata key" "$MAIN" \
  's|^    "windows-startup-script-ps1" = local.windows_host_startup$|    "windows-startup-script-ps1" = local.windows_host_startup_source|' \
  windows_boot_script_is_compressed
mutate "the wrapper handed the uncompressed text" "$MAIN" \
  's|^    gz = local.windows_host_startup_gz$|    gz = local.windows_host_startup_source|' \
  windows_boot_script_is_compressed
mutate "the compression local removed" "$MAIN" \
  's|^  windows_host_startup_gz     = base64gzip(local.windows_host_startup_source)$||' \
  windows_boot_script_is_compressed
mutate "the cap asserted for the Linux arm only" "$MAIN" \
  's|length(local.boot_script_metadata\[var.host_os == "windows" ? "windows-startup-script-ps1" : "startup-script"\]) < 262144|length(local.host_startup) < 262144|' \
  windows_boot_script_is_compressed

printf 'host-os-guard self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
