# dann.dclark.us — the host

A NixOS VPS. One Hermes agent installation (`hermes-agent`, declarative
`nixosModules.default` from the `hermes-agent` flake) serving five gifted AI pools, each with
its own provider entry and its own sops-managed credential.

| Item          | Value                                                                                  |
| ------------- | -------------------------------------------------------------------------------------- |
| Hostname      | `dann` (`dann.dclark.us`), NixOS 26.05 (Yarara)                                         |
| SSH           | `ssh -i ~/.ssh/dann_vps_ed25519 -o IdentitiesOnly=yes dann@dann.dclark.us`               |
| Service       | `hermes.service` running `hermes gateway` as user `hermes`                              |
| `HERMES_HOME` | `/var/lib/hermes/.hermes` (the module appends `environmentFiles` content to `.env`, `0600`) |
| Secrets       | sops → `/run/secrets/<NAME>` (`0400 root`), flat names = env var names                  |
| Upgrade       | `system.autoUpgrade` daily 04:00 ±45 min from the `deploy-dann` branch; manual: `systemctl start nixos-upgrade` |

Config lives in this repo, `nixos/dann/`; this file and the host's `system.autoUpgrade`
URL are the two places the host is wired to (see
[../../docs/migration-from-site-djbclark.md](../../docs/migration-from-site-djbclark.md)).

## The five pools

| Provider (Hermes entry)      | Pool                    | Model used for verification                        |
| ---------------------------- | ----------------------- | -------------------------------------------------- |
| `opencode-go-djbc`           | opencode-go, djbclark's | `deepseek-v4.1-flash`                              |
| `opencode-go-technoeuphora`  | opencode-go, techno-euphora's | `deepseek-v4.1-flash`                         |
| `cline-djbclark`             | clinepass, djbclark's   | `cline2-pass/deepseek-v4-flash`                    |
| `cline-technoeuphora`        | clinepass, techno-euphora's | `cline2-pass/deepseek-v4-flash`                |
| `bedrock` (built-in)         | AWS Bedrock             | `us.meta.llama4-scout-17b-instruct-v1:0`            |

Facts that are easy to get wrong again:

1. **No `inputs.nixpkgs.follows` on `hermes-agent`.** The module takes its package from
   `inputs.self.packages.<system>.default`, built against hermes's own nixpkgs pin; following
   the host's 26.05 substitutes an older Python and `nix/pythonLock.nix` throws.
2. **No `extraDependencyGroups`.** `packages.default` is already the `full` package and
   carries `bedrock` (boto3); naming the group swaps a cached package for a narrower uncached
   one.
3. **No `transport` / `api_mode` on the opencode-go entries.** Setting either pins the entry
   to one wire surface and the models on the other surface 503.
4. **Cline needs `max_tokens` ≥ 256**, and a `/models` 200 does **not** verify an
   opencode-go pool — the Go surface needs `Bearer`, a User-Agent and `x-opencode-session`.

## Verifying the pools

[`verify-pools.sh`](verify-pools.sh) checks, for each pool: the credential is present and
shaped right, and a real completion comes back through that provider. It prints status lines
only — no key, no key length beyond what the file itself declares.

```bash
# the host already has this exact script, installed from the repo at activation
ssh -i ~/.ssh/dann_vps_ed25519 -o IdentitiesOnly=yes dann@dann.dclark.us \
  "sudo -n -u hermes env HOME=/var/lib/hermes HERMES_HOME=/var/lib/hermes/.hermes \
   HERMES_MANAGED=true PATH=/run/current-system/sw/bin bash /etc/pool-verify/verify-pools.sh"
```

Run `/etc/pool-verify/verify-pools.sh`, not a copy you `scp` to `/tmp`: `environment.etc` installs
this file there on every activation, so the copy you run is the copy the timer runs. (To run it
somewhere else — a laptop — copy it, but then only the checks that need files on that machine
mean anything.)

Run as `dann` instead and the Hermes calls fail with `PermissionError` on `.env`; run as
`hermes` and the `/run/secrets` branch is unavailable (that sudo rule is `dann`'s), so the
secret check falls back to `$HERMES_HOME/.env`, which the module fills with the same lines.

Exit status: `0` all checks pass, `1` something failed (each failing line says what).
Exact key lengths are not in this repo — not because they are secret (a sops ciphertext is as
long as its plaintext, so [`secrets/pools.yaml`](secrets/pools.yaml) already publishes them) but
because they measure one host at one time. Supply them and the script compares them too:

```bash
POOL_EXPECT=~/.config/dann/pool-expectations bash verify-pools.sh   # NAME:bytes per line
```

Without that file the script checks presence, the `NAME=` prefix, a plausible length and a
real completion — which is what actually catches a bad, rotated or truncated key.

## The daily verification, and where its result goes

Since 2026-10-28 the host runs that same script itself, once a day, as a systemd oneshot
(`pool-verify.service`, `pool-verify.timer` at 05:20 UTC + up to 30 min; defined in
[`pool-verify.nix`](pool-verify.nix)). It runs as `hermes`, so nothing needs `dann`'s sudo rule,
and it writes both the journal and two files:

| Path | What |
| --- | --- |
| `/var/lib/pool-verify/last` | the whole report, first line `=== pool-verify <ISO time> exit=<n>` |
| `/var/lib/pool-verify/last.exit` | just the exit status; `0` means everything passed |

```bash
sudo -n systemctl start pool-verify          # run it now
journalctl -u pool-verify -n 80              # today's report
cat /var/lib/pool-verify/last                # the last report, timestamped
systemctl list-timers pool-verify            # when it next runs
```

The exact script that runs is installed at `/etc/pool-verify/verify-pools.sh` (from this repo at
activation, so it cannot drift). Expectations still work without a rebuild — drop them at
`/etc/pool-verify/expect` as `NAME:bytes` lines and the runner exports `POOL_EXPECT` pointing at
it. They live on the host, not in git, because they describe this host: an exact length changes
whenever a key is rotated, and a stale copy in a repo is worse than none. They are not secret —
the committed ciphertext in [`secrets/pools.yaml`](secrets/pools.yaml) is as long as the values
it holds.

The service writes both files as `hermes:hermes` with mode `0640` in a `0750` directory, so
`dann` reads them through the `hermes` group and other local users cannot.

**The host does not page anybody.** It has no messaging platform by design, so alerting lives off
the host: djbclark's `fleet-watch dann` (on his Mac, every 5 minutes) reads these two files over
ssh and sends one Telegram notice per incident — unreachable, failed upgrade, gateway down,
verification failed, verification stale (36 h), or failed units — and one on recovery. `fleet-watch
dann` reads the state on demand.

## Rotating a pool key

1. Get the new key from whoever owns that pool (djbclark or the operator). It never enters a
   chat, a shell argv or a commit.
2. Encrypt it into the sops file on a machine with the age recipients configured:
   `sops <cfg>/nixos/dann/secrets/pools.yaml` (or the scripted equivalent that reads the
   plaintext in memory and pipes to `sops -e /dev/stdin` — a bare `-` is rejected).
   Keep the line as `NAME=value`; the flat name **is** the environment variable.
3. Commit the ciphertext and push `master`, then fast-forward `deploy-dann`.
4. `systemctl start nixos-upgrade` on the host; confirm the new
   `/run/secrets/<NAME>` and that `enable`d `hermes.service` restarted the gateway.
5. Re-run `verify-pools.sh`. A rotated key that verifies nowhere was probably the wrong
   account: the mapping is fixed — `CLINE_API_KEY` → djbclark's pool,
   `CLINE_PASS_KEY_2_TE` → techno-euphora's.
6. Only after the new key passes: retire the old one with its owner. **The Mac-side uses of
   the same keys stay** (`CLINE_API_KEY` → litellm-local, `CLINE_PASS_KEY_2_TE` → cline2:
   fallback #1, compression, MoA, `AWS_BEARER_TOKEN_BEDROCK` → goose-scout, acp-run): the VPS
   copy is an additional consumer, not a replacement (djbclark, 2026-10-28: zero Mac removal).

`OPENCODE_GO_API_KEY` (unprefixed) is **not** one of the five pools; it belongs to djbclark
and must not be touched from here.

## Dann's own credentials (sudo-secretspec)

The host also holds **Dann's own** credentials, under the `sudo-secretspec` privilege boundary
([`sudo-secretspec.nix`](sudo-secretspec.nix) + [`secretspec-manifest.toml`](secretspec-manifest.toml)).
This is a *separate* secret family from the five pools above: those flow declaratively through
sops → `environmentFiles` → hermes `.env`, and this one is what the entity itself reads and
mutates at runtime.

Be accurate about what this boundary is on this host: **it is friction and an audit trail, not a
security boundary** — `dann` is root-equivalent (see `configuration.nix`), so nothing here stops a
`sudo cat` of the vault. It buys a named broker verb with a required `--reason` and a searchable
ledger. The honest statement, including the split below, is the design note in the source repo:
`docs/design/dann-deployment-threat-model.md` (frdminc/sudo-secretspec).

| Where                                    | Secret                                                                 |
| ---------------------------------------- | ---------------------------------------------------------------------- |
| sops `nixos/dann/secrets/sudo-secretspec.yaml` (owner `dann`, `0400`, **plain** values) | `GITHUB_TOKEN`, `GMAIL_OAUTH_CLIENT_ID`, `GMAIL_OAUTH_CLIENT_SECRET` |
| vault (`/var/lib/sudo-secretspec`, runtime) | `GMAIL_OAUTH_REFRESH_TOKEN` (rotates at runtime; re-auth after reinstall) |

Unlike the pools' `NAME=value` lines, these sops values are **bare** values: the consumer is
`dann` reading `/run/secrets/<NAME>` directly, so the file content *is* the credential.

To seed the vault on a fresh install, add the refresh token at runtime through the broker
(`sudo-secretspec source-add` / `source-set` with a `--reason`); the committed
`secretspec-manifest.toml` is declarations only, never values.
