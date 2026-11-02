# Pool → provider → model map

Four AI pools were gifted to the Dann entity on 2026-10-27/28 and wired onto
`dann.dclark.us` (Hermes, declarative NixOS module). Each is an independent consumer: the
**Mac-side uses of the same keys stay in place** — the VPS copy is an additional consumer, not
a replacement (djbclark, 2026-10-28, on signing off the Mac-removal list as *zero*).

| # | Hermes provider               | Credential (env var / sops key)      | Pool                   | Models                                        |
| - | ----------------------------- | ------------------------------------ | ---------------------- | --------------------------------------------- |
| 1 | `opencode-go-djbc`            | `OPENCODE_GO_API_KEY_DJBCLARK`       | opencode-go, djbclark  | `deepseek-v4.1-flash` (see `go-model-policy`) |
| 2 | `opencode-go-technoeuphora`   | `OPENCODE_GO_API_KEY_TECHNOEUPHORA`  | opencode-go, techno-euphora | same policy                              |
| 3 | `cline-djbclark`              | `CLINE_API_KEY`                      | clinepass, djbclark    | `cline2-pass/*`                               |
| 4 | `cline-technoeuphora`         | `CLINE_PASS_KEY_2_TE`                | clinepass, techno-euphora | `cline2-pass/*`                            |

The `bedrock` pool (`AWS_BEARER_TOKEN_BEDROCK`) was dropped 2026-11-01 on djbclark's instruction: its token returned HTTP 403 from Bedrock, and the daily `verify-pools.sh` PASS for it had only been the default fallback chain answering. Its ciphertext stays in `nixos/dann/secrets/pools.yaml` for a future rotation. The Mac's own use of that key (`goose-scout`, `acp-run`) is not changed by this and is djbclark's to manage.

Provider names are deliberately prefixed (`opencode-go-…`, `cline-…`) so the model id routes
through the right family without extra config. The opencode-go entries follow
`config/go-model-policy.json` (djbclark's Mac-side policy) rather than a frozen list here.

## Still in use on the Mac (do not retire with the VPS copies)

| Key                        | Mac consumer                                                       |
| -------------------------- | ------------------------------------------------------------------ |
| `CLINE_API_KEY`            | `litellm-local` (launchd job, `CLINEPASS_API_KEY`)                  |
| `CLINE_PASS_KEY_2_TE`      | `cline2`: fallback #1, compression, MoA (`~/.hermes/config.yaml`)  |

## Not one of the four

`OPENCODE_GO_API_KEY` (unprefixed) is a separate credential that stays with djbclark for its
own retirement; it is present in djbclark's `~/.hermes/.env` and must not be touched from
this site.

## What proves a secret is real

| Layer | Proves | Cannot see |
| ----- | ------ | ---------- |
| Static, CI (`secrets-encrypted.yml`) | Committed files have the shape of sops ciphertext for this host: `ENC[…]` values, the `sops:` metadata, the `recipient:` line. | Decryption. There is no private key in CI: a stale MAC, or ciphertext sealed to a different key than the `recipient:` line claims, passes. |
| Runtime, activation (sops-nix) | Every *declared* secret decrypts. An activation that cannot decrypt one fails, and the existing alarm path pages. | Nothing a failed activation does not surface; it does not run until a commit is deployed. |
| Daily, `verify-pools.sh` `=== sops` | Every declared secret's `/run/secrets/<NAME>` exists and is non-empty *right now*: evidence the last activation decrypted it. Size only; no byte is read. | Content, MAC, or which key sealed it. A present file is no proof a *future* commit decrypts. |

No check on this host can prove that a future commit decrypts before it is deployed: that takes
the next activation, and the alarm path is what makes a failure visible.
