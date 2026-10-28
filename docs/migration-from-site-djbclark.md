# Moving `dann.dclark.us`'s configuration out of `site-djbclark`

**State as of 2026-10-28.** djbclark's ruling: `dann.dclark.us` and Dann itself are a
*separate entity/site* from him. Dann's site is `site-dann` (public) + `site-private-dann`
(private); djbclark's are `site-djbclark` (public) and `site-private` (→ `site-private-djbclark`).

**Today the config still lives in djbclark's repo:**

| Piece                     | Where it is now                                                       |
| ------------------------- | --------------------------------------------------------------------- |
| NixOS config for the host | `site-djbclark/nixos/dann/` (`configuration.nix`, `disko.nix`, `hermes.nix`) |
| Flake + lock              | `site-djbclark/nixos/flake.nix` (shared with `vps-primary`, `?dir=nixos`) |
| sops secrets              | `site-djbclark/nixos/dann/secrets/{dann,pools}.yaml`                  |
| Deployed from             | `github:djbclark/site-djbclark/deploy-dann?dir=nixos#dann`            |
| What this repo has        | the runbooks and the verification harness, not the deployed source    |

## Why the move is staged, not a copy-paste

`system.autoUpgrade` on the host names that exact flake URL and branch. The moment the config
moves and the branch that the host pulls still builds the *old* tree, the host silently
freezes at an old revision while `nixos-upgrade` reports success. The switch has to be atomic
from the host's point of view, and reversible.

## Safe order

1. **Seed `site-dann/nixos/`** with a standalone flake: `nixpkgs` pinned to the same
   `nixos-26.05` revision, plus `disko`, `sops-nix`, `hermes-agent` (no
   `inputs.nixpkgs.follows`), and the same `dann`/`configuration.nix`/`hermes.nix`/secrets.
   Carry the lock across rather than re-resolving, so the closure is identical.
2. **Prove equivalence on the host**, revision-neutrally: build in a plain (non-git)
   directory on both sides so `self.rev` is null for both — otherwise the drv paths differ
   purely from `configurationRevision`. Compare the toplevel drv paths; they must match.
3. **Publish `deploy-dann` in `site-dann`** and push the new tree there.
4. **Flip the flake URL** in `configuration.nix` (`site-djbclark` → `site-dann`) — one commit
   in `site-djbclark`, promoted to its `deploy-dann`. This is the last commit that repo makes
   for this host: it deploys itself out of the job.
5. **Deploy and verify**: `systemctl start nixos-upgrade` on the host, then confirm the running
   system's revision is the new `site-dann` commit and `verify-pools.sh` still passes all five
   pools (the secrets must be re-declared in the new tree and reach `/run/secrets` unchanged).
6. **Retire the old location**: delete `nixos/dann/` from `site-djbclark` (leaving a pointer to
   this repo), keeping `vps-primary` and the rest of its flake untouched.
7. **Then** the harness can become a `verify-pools` command in `systemPackages` instead of a
   file staged at `/tmp`.

Rollback at any step before 6: revert the flake URL in `site-djbclark`, promote, upgrade again.
After 6: roll back by restoring `nixos/dann/` from git history and flipping the URL back.

## Constraint that does not change

Never edit `/etc/nixos` on the host and never run `nixos-rebuild` by hand. Deployment is
always: promote `master` → `deploy-dann`, then `systemctl start nixos-upgrade`.
