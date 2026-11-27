# Off-host encrypted backup design for `dann.dclark.us`

Status: **Design complete, stopped before target selection (2026-11-26).** Nothing in this
document provisions a remote target, creates an external account, spends money, or deploys to
`deploy-dann`. Target selection (Option 1, 2, or 3 below) awaits djbclark's ruling.

## 1. Why this exists and the threat model

Today `dann.dclark.us` has one provider-level backup: OVH `automatedBackup` (`enabled`, daily at
`05:07 UTC`, **`rotation: 1`**). That leaves two real gaps:

1. **Single-day, single-provider cliff.** `rotation: 1` holds one 24-hour restore point on the
   same provider. Silent corruption, an accidental deletion noticed after a day, or an OVH
   account/zone failure is unrecoverable from it.
2. **Root-equivalent host (`dann` is in `wheel` with `NOPASSWD: ALL`).** Per
   `nixos/dann/configuration.nix`, sudo on this host is friction, not a security boundary. Any
   backup design where `dann` holds delete or prune rights over its own remote repository allows
   a bad command or a compromised session to erase historical backups in one command.

**Non-negotiable invariant: append-only remote storage.** The credential held by `dann` may
**append** new encrypted snapshots and **read/verify** them; it must **never** be able to delete,
overwrite, or prune existing repository data. Retention pruning (`restic forget --prune`) runs
only from an off-host administrative credential that does not live on `dann`.

## 2. Repository split: two scopes, two passwords

Continuity state and secret-bearing vault state have different blast radii and restore needs. They
must never share one repository or one encryption password:

| Repository | Purpose | Included paths | Encryption password |
| --- | --- | --- | --- |
| **Repo A (`dann-continuity`)** | Entity continuity & non-secret host state | `/home/dann/.local/state/handoffs/`, active `/home/dann/.local/state/bigteam/`, SQLite `.backup` staging of `/home/dann/.local/share/opencode/opencode.db` (never the raw directory), and optionally a daily `git bundle` of any unpushed refs in `/home/dann/src/techno-euphora` | `RESTIC_PASSWORD_CONTINUITY` |
| **Repo B (`dann-vault`)** | Runtime-mutable credentials & audit ledger | SQLite `.backup` staging of `/var/lib/sudo-secretspec/secrets.db`, `broker-audit.sqlite3`, and `broker-history.sqlite3`, plus `/var/lib/sudo-secretspec/secretspec.toml` | `RESTIC_PASSWORD_VAULT` |

Why the split matters:
- Restoring the entity's continuity logs or session history onto a replacement box never requires
  exposing the vault decryption key.
- Repo B stays tiny (hundreds of kilobytes) and strictly isolated to runtime-mutable vault state
  and its hash-chained audit ledger.

## 3. Explicit exclusion list

The following paths are **excluded by construction** and must never enter either backup
repository:

1. **`/var/lib/sops-nix/key.txt`** — the host's private age decryption key. Including it alongside
   or inside backups collapses the sops encryption boundary. The operator maintains an offline,
   sealed recovery copy separately.
2. **`/home/dann/.ssh/` private keys** (`technoeuphora_ed25519`, `site-private-ro`, etc.) —
   host-bound identities; a rebuilt host mints or receives keys explicitly.
3. **`/var/lib/hermes/.hermes/.env`** — declaratively rendered by NixOS from `sops-nix` on
   activation (`nixos/dann/hermes.nix`); backing up plaintext `.env` duplicates static secrets.
4. **`/home/dann/.local/share/opencode/auth.json` and `log/`** — bearer tokens sit beside
   `opencode.db` in the same parent directory (`DESIGN-RESEARCH.md` §1.2). Backing up only the
   staged SQLite `.backup` of `opencode.db` guarantees `auth.json` never travels.
5. **`/home/dann/.cache/` and derived indexes** — rebuildable caches (including any future local
   Basic Memory `memory.db`, which is derived from git Markdown).

## 4. Pre-backup SQLite consistency hook

Live SQLite databases in WAL mode (`opencode.db`, `secrets.db`, `broker-audit.sqlite3`,
`broker-history.sqlite3`) must never be copied with plain file reads while writers may be active:
a mid-checkpoint read can capture a torn database.

Both backup units run a deterministic `backupPrepareCommand` and `backupCleanupCommand`:

1. Create a mode-`0700`, `root:root` staging directory under `/run/dann-backup-stage/<repo>/`
   (tmpfs, never persisted across reboot).
2. For each SQLite file, take an atomic, read-only online snapshot with `sqlite3`:
   ```sh
   timeout 120 sqlite3 -readonly "$src" ".timeout 5000" ".backup '$stage/$name'"
   ```
   (Skip absent optional sources like `opencode.db` only if explicitly marked optional; fail the
   run loudly if any required database in `/var/lib/sudo-secretspec` is unreadable or fails
   `.backup`.)
3. Run `restic backup` against the staged files plus the plain-file continuity paths.
4. `backupCleanupCommand` (always executed via systemd `ExecStopPost` / cleanup hook) wipes
   `/run/dann-backup-stage/<repo>/` so no extra unencrypted copy of `secrets.db` lingers on disk.

## 5. Secrets & recovery-key invariant (`sops-nix`)

Restic repository passwords and remote write credentials come from `sops-nix`, stored encrypted
in a dedicated file (`nixos/dann/secrets/backup.yaml`, sealed to `dann`'s age recipient, `0400
root`):

- `RESTIC_PASSWORD_CONTINUITY`
- `RESTIC_PASSWORD_VAULT`
- Target credential secret(s) (shape depends on chosen target: e.g. `RESTIC_REST_HTPASSWD` /
  `RESTIC_REPO_ENV` for `rest-server`, or scoped write-only `AWS_ACCESS_KEY_ID` +
  `AWS_SECRET_ACCESS_KEY` for S3/R2/B2)

**Human-held recovery copy invariant (mandatory):**
- **Never generate and store a restic password only on `dann`.** A password that exists solely on
  the host being backed up (or solely sealed to that host's age key without an off-host copy)
  creates the exact same single point of failure: losing `dann` would make the off-host backups
  undecryptable.
- Passwords must be generated off-host and stored in djbclark's off-host secret store
  (`sudo-secretspec` on the Mac / password manager) **before** sealing them into
  `nixos/dann/secrets/backup.yaml`.
- When `nixos/dann/backup.nix` is enabled, add each new sops secret name to `sops_report` in
  `nixos/dann/verify-pools.sh` and bump `EXPECTED_BASE_CHECKS` accordingly so daily verification
  confirms decryption on every activation (matching `docs/pools.md`).

## 6. Declarative NixOS module shape (`nixos/dann/backup.nix`)

When a target is chosen, the implementation lands as a self-contained module imported from
`nixos/dann/configuration.nix` (same pattern as `hermes.nix`, `pool-verify.nix`, and
`sudo-secretspec.nix`):

```nix
# Sketch — not yet imported; repository URLs and target env secrets await target selection.
{ config, pkgs, ... }:
{
  sops.secrets = {
    "RESTIC_PASSWORD_CONTINUITY" = { sopsFile = ./secrets/backup.yaml; owner = "root"; mode = "0400"; };
    "RESTIC_PASSWORD_VAULT"      = { sopsFile = ./secrets/backup.yaml; owner = "root"; mode = "0400"; };
    "RESTIC_TARGET_ENV"          = { sopsFile = ./secrets/backup.yaml; owner = "root"; mode = "0400"; };
  };

  services.restic.backups.dann-continuity = {
    # repository = "<TBD from chosen target>/dann-continuity";
    passwordFile = config.sops.secrets."RESTIC_PASSWORD_CONTINUITY".path;
    environmentFile = config.sops.secrets."RESTIC_TARGET_ENV".path;
    initialize = false; # initialized once off-host or during controlled commissioning
    paths = [
      "/home/dann/.local/state/handoffs"
      "/home/dann/.local/state/bigteam"
      "/run/dann-backup-stage/continuity"
    ];
    exclude = [
      "/home/dann/.local/share/opencode/auth.json"
      "/home/dann/.local/share/opencode/log"
      "/home/dann/.cache"
    ];
    extraBackupArgs = [ "--one-file-system" "--tag=dann-continuity" ];
    # NO pruneOpts here: the remote target is append-only; pruning runs off-host only.
    timerConfig = { OnCalendar = "*-*-* 05:25:00 UTC"; RandomizedDelaySec = "15m"; Persistent = true; };
    backupPrepareCommand = "...sqlite3 .backup of opencode.db into /run/dann-backup-stage/continuity...";
    backupCleanupCommand = "rm -rf /run/dann-backup-stage/continuity";
  };

  services.restic.backups.dann-vault = {
    # repository = "<TBD from chosen target>/dann-vault";
    passwordFile = config.sops.secrets."RESTIC_PASSWORD_VAULT".path;
    environmentFile = config.sops.secrets."RESTIC_TARGET_ENV".path;
    initialize = false;
    paths = [ "/run/dann-backup-stage/vault" ];
    extraBackupArgs = [ "--one-file-system" "--tag=dann-vault" ];
    # NO pruneOpts here: append-only remote.
    timerConfig = { OnCalendar = "*-*-* 05:30:00 UTC"; RandomizedDelaySec = "15m"; Persistent = true; };
    backupPrepareCommand = "...sqlite3 .backup of /var/lib/sudo-secretspec/{secrets.db,broker-audit.sqlite3,broker-history.sqlite3} + copy secretspec.toml into /run/dann-backup-stage/vault...";
    backupCleanupCommand = "rm -rf /run/dann-backup-stage/vault";
  };
}
```

Retention policy (executed **off-host** via admin credential, weekly):
`--keep-daily 14 --keep-weekly 8 --keep-monthly 6` (replacing OVH's 24-hour `rotation: 1` cliff
with six months of recovery points).

## 7. Verification, monitoring, and restore proof

*"A successful push is not a verified restore."*

1. **On-disk status markers for off-host alerting (`fleet-watch dann`):**
   Following `nixos/dann/pool-verify.nix`, `dann` does not run a messaging platform. Each backup
   and verify unit writes atomically (`*.new` → `mv -f`) to `/var/lib/dann-backup/` (directory
   mode `0750`, readable by `dann` for `fleet-watch` over SSH):
   - `continuity.last` / `continuity.exit`
   - `vault.last` / `vault.exit`
   - `verify.last` / `verify.exit`
2. **Weekly repository integrity check (`dann-backup-verify.timer`):**
   - Runs `restic check --read-data-subset=5%` on both `dann-continuity` and `dann-vault` to catch
     silent bit-rot or truncated pack files on the remote target.
3. **Weekly isolated restore drill with SHA-256 verification:**
   - **Repo A drill:** Restores `home/dann/.local/state/handoffs/chains/standalone-a276/SESSION_LOG.md`
     from the latest snapshot into an ephemeral `mktemp -d` directory, computes `sha256sum` on
     the restored file, and compares it against the SHA-256 recorded at backup time (stored in
     `continuity.last` or sidecar manifest) as well as confirming non-empty UTF-8 readability;
     deletes the temp directory on `trap EXIT`.
   - **Repo B drill:** Restores the latest `dann-vault` snapshot into a mode-`0700` ephemeral
     directory and runs `sqlite3 -readonly <db> "PRAGMA integrity_check;"` on `secrets.db`,
     `broker-audit.sqlite3`, and `broker-history.sqlite3` — proving decryption and SQLite
     structural integrity **without ever printing a secret value** — then deletes the temp
     directory on `trap EXIT`.
   - Any non-zero check, SHA-256 mismatch, or integrity failure writes non-zero to `verify.exit`
     so `fleet-watch dann` pages the operator.

## 8. Interim Tier 1 git mirror (already live)

While target selection is pending, the single highest-value non-git file
(`/home/dann/.local/state/handoffs/chains/standalone-a276/SESSION_LOG.md`) is mirrored daily by
a host user timer (`tier1-mirror.timer` → `/home/dann/.local/bin/tier1-mirror.sh`) into
`techno-euphora`'s `agents/state/handoffs/standalone-a276/SESSION_LOG.md` (unconditional copy,
detached worktree from `origin/main`, no `git pull`, atomic `last.run` / `last.exit` under
`/home/dann/.local/state/tier1-mirror/`).

Note for the next `site-dann` NixOS promotion: declare `users.users.dann.linger = true;` in
`nixos/dann/configuration.nix` so user-systemd lingering survives a full reinstall declaratively
(currently enabled imperatively via `loginctl enable-linger dann`).

## 9. Off-host target options — STOPPED HERE pending operator ruling

Nothing below is selected, requested, or provisioned. Activation of `nixos/dann/backup.nix`
requires djbclark's choice of target and the three resulting inputs (`repository` URI, target
credential sops key, and off-host prune schedule):

1. **Option 1 — Append-only `restic rest-server` on `vps-primary` or `vps-hub` (Hetzner):**
   Cross-provider from OVH BHS, **$0/mo** incremental spend, native `--append-only` enforcement on
   the server side. Requires the `site-public-djbclark` lead to expose a dedicated per-host
   append-only rest-server endpoint and off-host prune timer.
2. **Option 2 — Independent cloud object store (Cloudflare R2 or Backblaze B2):**
   Independent of both OVH and Hetzner, minimal spend (R2 10 GB free tier or B2 pennies/month),
   append-only via Object Lock / scoped write-only app key. Requires operator account/bucket
   creation and billing approval.
3. **Option 3 — Phased 3-2-1 (recommended):**
   Ship **Option 1** first to eliminate the single-provider 24-hour cliff at $0/mo, then add
   **Option 2** as a second independent off-site leg before Phase 1 Basic Memory cutover.
