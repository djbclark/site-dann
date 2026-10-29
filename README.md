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

**Migration done, 2026-10-28.** This repo is the deployed source for `dann.dclark.us`:
`github:djbclark/site-dann/deploy-dann?dir=nixos#dann`. The host switched from
`site-djbclark` and now reports this repo's revision
(`nixos-version --configuration-revision`); `site-djbclark/nixos/dann/` is a pointer only.
The move was proved closure-neutral before it happened (identical toplevel drv from both
trees) — see [docs/migration-from-site-djbclark.md](docs/migration-from-site-djbclark.md).

Weekly, [`.github/workflows/nixos-lock-update.yml`](.github/workflows/nixos-lock-update.yml)
bumps `nixos/flake.lock`, **builds `dann` on the runner as the gate**, commits the lock to
`master` and fast-forwards `deploy-dann` to it — the host itself runs `upgrade = false`, so this
workflow is the only thing that ever moves its inputs. A failure, or nixos changes left
unpromoted on `master`, opens one `nixos-lock` issue and pings Telegram; the issue closes itself
when a later run finds nothing outstanding. It needs `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID` and `TELEGRAM_THREAD_ID` as repository secrets — again after this repo moves
to Dann's own account.

## Working in this repo

`master` is the working branch; deployments read long-lived `deploy-*` branches promoted from
`master` (the flow inherited from djbclark's sites, documented in
`docs/migration-from-site-djbclark.md`). Commit and push your own changes per unit.
