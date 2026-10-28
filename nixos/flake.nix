{
  description = "Dann's NixOS hosts (dann.dclark.us)";

  # This flake owns exactly one host: `dann`. It was split out of djbclark's
  # site-djbclark/nixos flake on 2026-10-28, when dann.dclark.us became its own site
  # (site-dann) rather than a host in his repo. The lock was carried across verbatim and
  # only the unrelated root inputs (athena-nixos, bb-nix, nixathena, paseo-nix, used by
  # his vps-primary) were pruned, so the closure is byte-identical to what the host was
  # already running — see docs/migration-from-site-djbclark.md.

  # The stable branch the host runs. Which commit is built is decided by flake.lock alone.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  # disko: declarative disk partitioning, used by nixos-anywhere to install the host from
  # scratch and to keep the layout reviewable in git.
  inputs.disko = {
    url = "github:nix-community/disko";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  # sops-nix: secrets encrypted in git, decrypted on the host at activation by its age key.
  #
  # WHY THIS IS SAFE IN A PUBLIC REPO: only the CIPHERTEXT is committed. The host's private
  # age key lives at /var/lib/sops-nix/key.txt (mode 0600, generated ON the host, never
  # transmitted) and is deliberately NOT in this repo or in git anywhere. Recipients:
  # .sops.yaml at the repo root.
  inputs.sops-nix = {
    url = "github:Mic92/sops-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # hermes-agent: the agent runtime serving the five gifted AI pools on this host. A flake
  # input rather than a nixpkgs package because the runtime ships its own declarative NixOS
  # module (`nixosModules.default`), which is the only supported install path — the
  # `curl | bash` installer is not used anywhere here.
  #
  # NO `inputs.nixpkgs.follows = "nixpkgs"` HERE, deliberately. The module takes its package
  # from this flake's own `packages.<system>.default`, built against this flake's own nixpkgs
  # pin (nixos-unstable). Following the host's nixos-26.05 would substitute an older Python,
  # and nix/pythonLock.nix THROWS rather than guess when the interpreter family does not
  # match pm/lock.json (checked 2026-10-27: the pin gives python 3.14.7, exactly the lock's
  # family). The host's nixpkgs is therefore not a constraint on this package at all.
  inputs.hermes-agent.url = "github:djbclark/hermes-agent";

  outputs =
    {
      self,
      nixpkgs,
      disko,
      hermes-agent,
      sops-nix,
      ...
    }:
    {
      # dann.dclark.us. disko.nixosModules.disko is imported HERE rather than in
      # configuration.nix, because the disk layout is an installation-time concern; keeping
      # it in the flake is what lets `nixos-anywhere --flake .#dann` find the layout and the
      # system in one place. The layout itself is ./dann/disko.nix, pulled in by disko's own
      # `disko.devices` option.
      nixosConfigurations.dann = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          # `services.hermes-agent` — declared in ./dann/hermes.nix. Imported BEFORE the host
          # config so the host file can read `config.sops.secrets` paths it defines.
          hermes-agent.nixosModules.default
          ./dann/configuration.nix
          ./dann/disko.nix
          # `nixos-version --configuration-revision` on the host then names the git commit.
          { system.configurationRevision = self.rev or self.dirtyRev or null; }
        ];
      };
    };
}
