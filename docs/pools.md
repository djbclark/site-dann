# Pool → provider → model map

Five AI pools were gifted to the Dann entity on 2026-10-27/28 and wired onto
`dann.dclark.us` (Hermes, declarative NixOS module). Each is an independent consumer: the
**Mac-side uses of the same keys stay in place** — the VPS copy is an additional consumer, not
a replacement (djbclark, 2026-10-28, on signing off the Mac-removal list as *zero*).

| # | Hermes provider               | Credential (env var / sops key)      | Pool                   | Models                                        |
| - | ----------------------------- | ------------------------------------ | ---------------------- | --------------------------------------------- |
| 1 | `opencode-go-djbc`            | `OPENCODE_GO_API_KEY_DJBCLARK`       | opencode-go, djbclark  | `deepseek-v4.1-flash` (see `go-model-policy`) |
| 2 | `opencode-go-technoeuphora`   | `OPENCODE_GO_API_KEY_TECHNOEUPHORA`  | opencode-go, techno-euphora | same policy                              |
| 3 | `cline-djbclark`              | `CLINE_API_KEY`                      | clinepass, djbclark    | `cline2-pass/*`                               |
| 4 | `cline-technoeuphora`         | `CLINE_PASS_KEY_2_TE`                | clinepass, techno-euphora | `cline2-pass/*`                            |
| 5 | `bedrock` (Hermes built-in)   | `AWS_BEARER_TOKEN_BEDROCK`           | AWS Bedrock            | `us.meta.llama4-*`, region mirrored in config |

Provider names are deliberately prefixed (`opencode-go-…`, `cline-…`) so the model id routes
through the right family without extra config. The opencode-go entries follow
`config/go-model-policy.json` (djbclark's Mac-side policy) rather than a frozen list here.

## Still in use on the Mac (do not retire with the VPS copies)

| Key                        | Mac consumer                                                       |
| -------------------------- | ------------------------------------------------------------------ |
| `CLINE_API_KEY`            | `litellm-local` (launchd job, `CLINEPASS_API_KEY`)                  |
| `CLINE_PASS_KEY_2_TE`      | `cline2`: fallback #1, compression, MoA (`~/.hermes/config.yaml`)  |
| `AWS_BEARER_TOKEN_BEDROCK` | `goose-scout`, `acp-run`                                            |

## Not one of the five

`OPENCODE_GO_API_KEY` (unprefixed) is a separate credential that stays with djbclark for its
own retirement; it is present in djbclark's `~/.hermes/.env` and must not be touched from
this site.
