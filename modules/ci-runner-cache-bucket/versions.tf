terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source = "hashicorp/google"

      # 5.34.0 rather than the >= 5.0 the other modules carry, and the reason is
      # `soft_delete_policy`: the provider grew that block in 5.34.0, partway
      # through the 5.x line, to match Google turning soft delete on by default.
      # So >= 5.0 would ADMIT a provider that cannot express it, while this
      # floor is the actual first release that can — not a major-version
      # boundary chosen because the exact minor was unknown.
      #
      # It is worth a floor at all because the failure is quiet in one
      # direction: a provider that rejects the argument fails the plan loudly,
      # but one that ignores it leaves the bucket on Google's 7-day soft-delete
      # default, retaining every expired snapshot past the age bound that is
      # this module's only security control.
      version = ">= 5.34.0"
    }
  }
}
