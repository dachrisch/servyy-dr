# Credential sources for DR

The public repo is assumed readable by adversaries. It names no infrastructure
details and contains no plaintext credentials.

- The encrypted bundle contains only what is needed to reach the backup before
  the private environment is available.
- The DR passphrase lives only in the Vaultwarden item named in the runbook.
- Controller-only configuration and secrets are not stored in git. They are
  restored from the home backup during DR and remain on the controller during
  normal operation.
- The bundle sidecar and offline staleness guard live in the private repo.
  Regenerate, publish and commit the sidecar together after changing any bundle
  input.
