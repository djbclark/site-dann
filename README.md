# site-dann

**Dann's site repo.** It owns the machines, services and host-side tooling that belong to
Dann — the composite entity's seats that work on `dann.dclark.us` — as a *separate entity*
from djbclark's site (2026-10-28, djbclark's ruling).

| Site              | Repo                                       | Owner                     | Owns                                                             |
| ----------------- | ------------------------------------------ | ------------------------- | ---------------------------------------------------------------- |
| djbclark (public) | [site-djbclark](https://github.com/djbclark/site-djbclark) | djbclark    | his laptops, his VPSs, his inventories                            |
| djbclark (private)| `site-private` (→ `site-private-djbclark`)  | djbclark                  | his private memory, secrets-adjacent notes                        |
| **Dann (public)** | **this repo**                              | **Dann**                  | **`dann.dclark.us` and Dann's own host-side tooling**             |
| Dann (private)    | [site-private-dann](https://github.com/djbclark/site-private-dann) | Dann | Dann's private memory and diagnostics (exact key lengths, hosts)  |

djbclark's repos are **reference material, not this site's content**: copy patterns from them
freely, but Dann's host facts, runbooks and diagnostics live here or in `site-private-dann`.

## What is here

| Path                            | What                                                                                       |
| ------------------------------- | ------------------------------------------------------------------------------------------ |
| `AGENTS.md`                     | Entry point for any agent session (identity, secrets, deployment rules). `CLAUDE.md` symlinks it. |
| `nixos/dann/README.md`          | The host: `dann.dclark.us`, its Hermes install, the five gifted AI pools, rotation runbook  |
| `nixos/dann/verify-pools.sh`    | Per-pool verification harness — run on the host, prints status lines only                    |
| `docs/migration-from-site-djbclark.md` | Where the host config lives today, and the safe order for moving it here            |
| `docs/pools.md`                 | The pool → provider → model map and what each pool is for                                    |

## Status

The NixOS configuration for `dann.dclark.us` still lives in
[`site-djbclark/nixos/dann/`](https://github.com/djbclark/site-djbclark/tree/master/nixos/dann)
and deploys from that repo's `deploy-dann` branch. Moving it here is an open task with a
deliberate order — see
[docs/migration-from-site-djbclark.md](docs/migration-from-site-djbclark.md). Until that
switch happens, treat this repo as the *destination and the runbooks*, not the deployed source.

## Working in this repo

`master` is the working branch; deployments read long-lived `deploy-*` branches promoted from
`master` (the flow inherited from djbclark's sites, documented in
`docs/migration-from-site-djbclark.md`). Commit and push your own changes per unit.
