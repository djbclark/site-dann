# Moving `dann.dclark.us`'s configuration out of `site-djbclark`

**State as of 2026-10-28: DONE — the host builds from this repo.** djbclark's ruling:
`dann.dclark.us` and Dann itself are a *separate entity/site* from him. Dann's site is
`site-dann` (public, this repo) + `site-private-dann` (private); djbclark's are
`site-djbclark` (public) and `site-private` (→ `site-private-djbclark`).

What actually happened, in order:

1. Seeded `nixos/` here as a standalone flake, carrying `flake.lock` across verbatim and
   pruning only the root inputs `vps-primary` needs (`athena-nixos`, `bb-nix`, `nixathena`,
   `paseo-nix`).
2. Proved equivalence on the host, revision-neutrally (both trees in plain, non-git
   directories so `self.rev` is null on both): **identical toplevel drv**,
   `/nix/store/phnyziwdam8cl8ijpia46bfyb9j70s1k-nixos-system-dann-26.05.20261025.1f607aa.drv`.
3. Published `deploy-dann` here at `cc9311a`; the host resolved the URL and inputs before
   anything was switched.
4. Flipped the one line in `site-djbclark/nixos/dann/configuration.nix` (`cd74f2e`),
   promoted it to that repo's `deploy-dann`, ran `systemctl start nixos-upgrade` → the host
   came up on `cd74f2e`.
5. Ran `systemctl start nixos-upgrade` again — the first run that actually read this repo →
   the host reported `cc9311a`, `hermes-agent` active/enabled, `NRestarts=0`, and
   `verify-pools.sh` passed **12/12** (secrets unchanged through the new sops path).
6. Retired `nixos/dann/` and the `dann` output + its three inputs from
   `site-djbclark/nixos/flake.nix`, having first proved `vps-primary`'s toplevel drv was
   unchanged by the pruning.
7. **2026-10-28, later:** deleted `site-djbclark`'s `deploy-dann` branch (was `cd74f2e`, the
   retirement trampoline) and the remaining `nixos/dann/` pointer, once the host had been
   verified on this repo (`c473b5f`, `pool-verify.timer` active). Rollback is no longer
   "promote that branch": it is restoring the tree from `site-djbclark`'s git history and
   flipping the URL in `nixos/dann/configuration.nix` back, per the block below.

Rollback: the old tree is in `site-djbclark`'s git history (`git show cd74f2e:nixos/dann/…`),
and the host's previous generations are still on disk. Nothing has been deleted without
history.

## Why the move was staged, not a copy-paste

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
After 6: roll back by restoring `nixos/dann/` from `site-djbclark`'s git history (`cd74f2e`) and
flipping the URL in `nixos/dann/configuration.nix` back here — after step 7 there is no branch
there to promote to, so this is a rebuild in this repo, not a switch in that one.

## What the split gives up, deliberately

`site-djbclark` has a weekly workflow (`.github/workflows/nixos-lock-update.yml`) that bumps
`nixos/flake.lock`, builds `vps-primary` as the gate, and promotes it. While `dann` lived in
that flake it inherited the bump. After the move, **nothing bumps `dann`'s `nixpkgs`** — the
host runs `upgrade = false`, so its pin only moves when a commit here moves the lock.

That gap is closed: [`.github/workflows/nixos-lock-update.yml`](../.github/workflows/nixos-lock-update.yml)
in this repo does the same job for `dann` — weekly lock bump, `dann`'s toplevel built on the
runner as the gate, commit to `master`, fast-forward `deploy-dann` when nothing else under
`nixos/` is waiting, one `nixos-lock` issue plus a Telegram message on failure. It bumps every
input (disko, sops-nix, hermes-agent too), which is safe only because the runner builds the
result before anything is promoted.

## Constraint that does not change

Never edit `/etc/nixos` on the host and never run `nixos-rebuild` by hand. Deployment is
always: promote `master` → `deploy-dann`, then `systemctl start nixos-upgrade`.
