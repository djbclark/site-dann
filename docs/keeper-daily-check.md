# The keeper's daily marker read

One command, nineteen assertions, one exit status:

```bash
<site-dann>/nixos/dann/keeper-marker-read.py            # --fetch to refresh deploy-dann first
```

Exit `0` = everything holds. Exit `1` = at least one `FAIL` line, and the failing line says which
measurement broke. Exit `2` = the host was unreachable, so nothing is being asserted at all — read
that as "unknown", never as "fine".

## Where it runs, and why it is not on the host

**It runs on the operator's Mac.** The OVH credential (`OVH_APPLICATION_KEY`,
`OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`, `OVH_ENDPOINT`) exists only in the Mac's
`sudo-secretspec`. The host's sops store publishes seven names — `GITHUB_TOKEN`,
`GMAIL_OAUTH_CLIENT_ID`, `GMAIL_OAUTH_CLIENT_SECRET`, `OPENCODE_GO_API_KEY_DJBCLARK`,
`OPENCODE_GO_API_KEY_TECHNOEUPHORA`, `CLINE_API_KEY`, `CLINE_PASS_KEY_2_TE` — and **none of them is
OVH** (verified on the host 2026-11-28, `ls /run/secrets`).

So a host-side OVH watcher would have to deploy a new credential to a public box to run a monitor.
The lead ruled against exactly that on 2026-11-28: *"yes ONLY if it reuses the OVH credential that
is already on the host and adds no new secret … if it turns out to need a new secret, stop."* It did
turn out to need one, so the assertion moved to where the credential already is and **no second
timer was created** — this folds into the read the keeper already performs.

## What it asserts

| # | Assertion | Source |
| --- | --- | --- |
| 1–2 | Host revision matches the `deploy-dann` head | `nixos-version --configuration-revision` vs local `origin/deploy-dann` |
| 3 | Uptime, load, available memory reported | `/proc` |
| 4 | Root filesystem under 90% | `df` |
| 5–6 | No failed system or user units | `systemctl --failed` |
| 7 | `nixos-upgrade.timer` last run succeeded | `systemctl show nixos-upgrade.service -p Result -p ExecMainStatus` |
| 8 | `pool-verify` PASS 18/18 | `/var/lib/pool-verify/last{,.exit}` |
| 9 | `tier1-mirror` ran clean | `~/.local/state/tier1-mirror/last.run` |
| 10 | The Tier 1 live file is byte-identical to the repo mirror | sha256 of both files |
| 11 | The host checkout is clean and level with `origin/main` | `git status --porcelain=v1 -b` |
| 12 | The only public listener port is 22 | `ss -tulpnH` |
| 13 | The firewall is active and allows ssh with a default-refuse rule | `iptables -S` (`nixos-fw`) |
| 14–15 | OVH: VPS `running`, unlocked, 6 vCore / 12 GB / 100 GB | `GET /vps/<service>` |
| 16 | OVH: `automatedBackup` `enabled`, `rotation: 1`, daily 05:07 | `GET /vps/<service>/automatedBackup` |
| 17–18 | OVH: service `status: ok`, `renew.automatic`, not `deleteAtExpiration`, not expired | `GET /vps/<service>/serviceInfos` |
| 19 | OVH: expiry sits on a ~1 month cycle, i.e. it *renewed* rather than lapsed | derived from `expiration` |

Item 19 is the one that cost a wrong read once. A monthly plan's `expiration` is not a warning: it
is the billing period. What is worth asserting is that the date **moved** — on 2026-11-28 it read
`2026-12-01` where the install-time value was `2026-11-24`, which is the only evidence the API
offers that automatic renewal actually happened.

The lead's phrasing of why, kept verbatim because it is the whole argument (2026-11-28): *"'the date
moved by about a month' is evidence of renewal; 'the date is in the future' is evidence of
nothing."*

## What makes it safe to run unattended

1. **GET only.** `ovh-api.py` refuses any non-GET method unless `--allow-write` is passed, and
   refuses billable paths as well — that guard is in code, not in a comment.
2. **The credential never enters this process.** The OVH leg is a child of
   `sudo-secretspec run --reason "read-only: …"`, so the values exist only inside that child, and
   the script prints parsed fields rather than a response body.
3. **Nothing on the host is written.** Every host-side command is a read; the only write anywhere is
   `git fetch` on the local clone, and only behind the `--fetch` opt-in (it moves `origin/*` refs and
   nothing else).
4. **It can fail.** Proven deliberately on 2026-11-28 by pointing `--ovh-service` at a nonexistent
   service: three `FAIL` lines and exit `1`. A watcher that cannot fail is decoration.

> **Invariant on edit (lead, 2026-11-28): keep both properties.** Exit `2` when the host is
> unreachable so "unknown" cannot read as fine, and a deliberate proof that the script does fail.
> Either one lost turns this back into a script that prints reassuring lines.
>
> **And if a future assertion seems to need a credential on the host, that is a stop-and-ask, never
> a deployment.** The reason this design has no new secret is that the premise was checked rather
> than complied with.

## What it deliberately does not do

1. **No history.** One point in time. A daily `FAIL` is the signal; the script keeps no log of its
   own on purpose, because the durable record is the message the keeper sends when something breaks.
2. **No restore drill.** Restoring the OVH backup overwrites the host, and the provider gives one
   restore point — that belongs to the off-host backup work
   (`docs/off-host-backup-design.md`), not to a daily read.
3. **No wake, no alert.** It asserts and prints. Delivering a `FAIL` to anyone is the keeper's job
   in the session that sees it, through `peer_mail.py` and `hermes-ping`, so there is no second
   notification path to drift out of date.

## Reporting the result

Silence is only correct for a green day with nothing changing (lead, 2026-11-28). Send a line to the
lead when either happens:

1. **A check fails.** The `FAIL` line, the measurement, and what was or was not done about it —
   immediately, not at the next scheduled read.
2. **A held decision changes, or real work begins.** The backup target being chosen, Eve's token
   landing, the memory move starting, or the first commit of a new piece of host work. *"I do not
   want my only view of the host to be bad news."*

A wholly green daily read with nothing unblocked needs no message.
