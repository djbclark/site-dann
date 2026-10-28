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

Config lives in `site-djbclark/nixos/dann/` today (see
[../docs/migration-from-site-djbclark.md](../docs/migration-from-site-djbclark.md)).

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
# copy it up, then run it as the hermes service user
scp -i ~/.ssh/dann_vps_ed25519 -o IdentitiesOnly=yes nixos/dann/verify-pools.sh \
  dann@dann.dclark.us:/tmp/verify-pools.sh
ssh -i ~/.ssh/dann_vps_ed25519 -o IdentitiesOnly=yes dann@dann.dclark.us \
  "sudo -n -u hermes env HOME=/var/lib/hermes HERMES_HOME=/var/lib/hermes/.hermes \
   HERMES_MANAGED=true PATH=/run/current-system/sw/bin bash /tmp/verify-pools.sh"
```

Run as `dann` instead and the Hermes calls fail with `PermissionError` on `.env`; run as
`hermes` and the `/run/secrets` branch is unavailable (that sudo rule is `dann`'s), so the
secret check falls back to `$HERMES_HOME/.env`, which the module fills with the same lines.

Exit status: `0` all checks pass, `1` something failed (each failing line says what).
Expected key lengths are **not** in this public repo; supply them privately and the script
compares them too:

```bash
POOL_EXPECT=~/.config/dann/pool-expectations bash verify-pools.sh   # NAME:bytes per line
```

Without that file the script checks presence, the `NAME=` prefix, a plausible length and a
real completion — which is what actually catches a bad, rotated or truncated key.

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
