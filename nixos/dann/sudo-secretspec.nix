# The entity's own credentials and the sudo-secretspec privilege boundary.
#
# WHY THIS EXISTS ON DANN, AND WHAT IT IS NOT: the boundary is NOT a security boundary here.
# `configuration.nix` grants `%wheel ALL=(ALL:ALL) NOPASSWD:SETENV: ALL` and puts `dann` in
# wheel with `wheelNeedsPassword = false`, so `dann` is root-equivalent and can `sudo cat` the
# vault directly. What sudo-secretspec provides on this host is exactly two things:
#
#   1. reason-forcing friction — a credential operation goes through a named broker verb with a
#      required `--reason`, recorded in the ledger, instead of a bare `sudo cat`;
#   2. a convenience audit trail — the ledger is a searchable record of what was read or
#      written, when, and why.
#
# The authoritative, honest statement of this (and why no pool key or Google password is here)
# is the design note in the sudo-secretspec repo:
#   https://github.com/frdminc/sudo-secretspec/blob/sudo-main/docs/design/dann-deployment-threat-model.md
# (H6/M1). Read it before changing what goes in the vault.
#
# THE SPLIT (that note's M1 table): static secrets stay in SOPS; only secrets the entity mutates
# at runtime live in the vault. The pool keys (hermes.nix) are in neither — they are declarative
# sops → environmentFiles → hermes `.env`, and a second mutable copy would drift.
#
#   sops — ./secrets/sudo-secretspec.yaml (owner=dann 0400)        vault — via the manifest below
#   GITHUB_TOKEN               dann-clark classic token (40 chars)  GMAIL_OAUTH_REFRESH_TOKEN
#   GMAIL_OAUTH_CLIENT_ID      OAuth app config (not high value)     (rotates at runtime; re-auth
#   GMAIL_OAUTH_CLIENT_SECRET  OAuth app config (not high value)      after a reinstall)
#
# These sops values are PLAIN values, not `NAME=value` lines: unlike hermes.nix's pools.yaml
# (whose consumer is environmentFiles, which wants `.env` syntax), the consumer here is `dann`
# reading `/run/secrets/<NAME>` directly, so the file content IS the credential.
{ lib, ... }:

{
  # ── The entity's static credentials (sops) ───────────────────────────────────────────────
  # One encrypted file for the whole group, next to the one consumer (this module), exactly the
  # pattern hermes.nix uses for pools.yaml. The three keys are encrypted with real values and the
  # module builds on the host (live since 2026-10-28). `validateSopsFiles = true`
  # (configuration.nix) only checks that each declared key EXISTS in the encrypted file: sops-nix
  # runs sops-install-secrets with `-check-mode=sopsfile`, which reads and parses the file and
  # looks the key up, and never decrypts. So a missing key or a missing/unparseable file fails the
  # build, but a placeholder string stored under the right key evaluates clean and is deployed, and
  # so is a file not encrypted to the host's age recipient (activation then cannot decrypt it).
  # Neither is caught here. The recipient check belongs in .github/workflows/secrets-encrypted.yml
  # (being extended separately; do not read it as complete: a valid recipient with a broken MAC
  # would still get through).
  sops.secrets = lib.genAttrs [
    "GITHUB_TOKEN"
    "GMAIL_OAUTH_CLIENT_ID"
    "GMAIL_OAUTH_CLIENT_SECRET"
  ] (_: {
    sopsFile = ./secrets/sudo-secretspec.yaml;
    owner = "dann";
    group = "users";
    mode = "0400";
  });

  # ── The privilege boundary ────────────────────────────────────────────────────────────────
  # The module is `sudo-secretspec.nixosModules.default` from the flake input (wired in
  # nixos/flake.nix). serviceUser/serviceGroup/vault/profile take the module defaults
  # ("sudo-secretspec" for both service names, /var/lib/sudo-secretspec, "default"). Set here:
  # `operator` (the module has no default for it) and the declarations template.
  services.sudo-secretspec = {
    enable = true;
    operator = "dann";
    declarations = ./secretspec-manifest.toml;
  };

  # The imported module derives the sudoers policy from the broker binary itself via
  # import-from-derivation (its H3 decision), so evaluation needs this. Set here — at the one
  # site that actually imports the module — rather than in the upstream module, and mirrored in
  # .github/workflows/nixos-lock-update.yml for the runner.
  nix.settings.allow-import-from-derivation = true;
}
