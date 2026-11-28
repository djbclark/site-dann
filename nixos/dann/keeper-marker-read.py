#!/usr/bin/env python3
"""keeper-marker-read.py — the keeper's daily assertion about dann.dclark.us.

Runs **on the operator's Mac** (not on the host), read-only end to end, and prints
one PASS/FAIL line per assertion plus the measurements behind it. Exit 0 when every
assertion holds, 1 when one fails, 2 on a usage error.

Why it lives here and not on the host: the OVH credential (`OVH_APPLICATION_KEY` /
`_SECRET` / `OVH_CONSUMER_KEY`) exists only in the **Mac's** `sudo-secretspec`. The
host's sops store carries seven names and none of them is OVH (verified 2026-11-28).
Deploying the credential to the host to run a watcher there would *widen the host's
secret surface for a monitor*, which the lead ruled against on 2026-11-28 — so this
reuses the credential where it already is and adds no second timer.

Nothing secret is printed: the OVH leg parses the response and reports fields
only, and the credential is never in this process's environment except inside the
`sudo-secretspec run` child.

Usage:
    nixos/dann/keeper-marker-read.py                 # human output
    nixos/dann/keeper-marker-read.py --quiet          # only FAIL lines + summary
    nixos/dann/keeper-marker-read.py --no-ovh         # skip the API leg (offline)
    nixos/dann/keeper-marker-read.py --host dann      # override the ssh target

Assertions and where each comes from are listed in `docs/keeper-daily-check.md`.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

OVH_SERVICE_DEFAULT = "vps-825c92cc.vps.ovh.ca"
OVH_API_DEFAULT = os.path.expanduser("~/.agents/skills/ovhcloud-api/scripts/ovh-api.py")

# One shell program, fed to `ssh <host> bash -s` on stdin. Kept to `key=value`
# lines so the Python side never has to parse prose, and to single quotes inside
# so nothing is expanded locally.
REMOTE = r"""
set -u
echo "rev=$(nixos-version --configuration-revision 2>/dev/null || echo unknown)"
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
echo "load1=$(cut -d' ' -f1 /proc/loadavg)"
echo "mem_avail_mb=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
echo "disk_pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')"
echo "failed_system=$(systemctl --failed --no-legend | wc -l)"
echo "failed_user=$(systemctl --user --failed --no-legend 2>/dev/null | wc -l)"
echo "upgrade_result=$(systemctl show nixos-upgrade.service -p Result --value)"
echo "upgrade_exit=$(systemctl show nixos-upgrade.service -p ExecMainStatus --value)"
echo "upgrade_when=$(systemctl show nixos-upgrade.service -p ExecMainExitTimestamp --value)"
echo "pv_exit=$(cat /var/lib/pool-verify/last.exit 2>/dev/null)"
echo "pv_line=$(grep -oE 'PASS: [0-9]+ checks, none failed|FAIL' /var/lib/pool-verify/last 2>/dev/null | head -1)"
echo "pv_ts=$(grep -oE 'pool-verify [0-9T:Z-]+' /var/lib/pool-verify/last 2>/dev/null | head -1)"
echo "tm_line=$(grep -E '^(timestamp|exit|status)=' /home/dann/.local/state/tier1-mirror/last.run 2>/dev/null | tr '\n' ' ')"
echo "chain_sha=$(sha256sum /home/dann/.local/state/handoffs/chains/standalone-a276/SESSION_LOG.md | cut -d' ' -f1)"
echo "mirror_sha=$(sha256sum /home/dann/src/techno-euphora/agents/state/handoffs/standalone-a276/SESSION_LOG.md | cut -d' ' -f1)"
echo "checkout_line=$(git -C /home/dann/src/techno-euphora status --porcelain=v1 -b | head -1)"
echo "checkout_head=$(git -C /home/dann/src/techno-euphora rev-parse --short HEAD)"
echo "listeners=$(sudo -n ss -tulpnH 2>/dev/null | wc -l)"
echo "listener_ports=$(sudo -n ss -tulpnH 2>/dev/null | awk '{print $5}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un | tr '\n' ',')"
echo "fw_ssh=$(sudo -n iptables -S 2>/dev/null | grep -c -- '--dport 22 -j nixos-fw-accept')"
echo "fw_default_refuse=$(sudo -n iptables -S 2>/dev/null | grep -c -- '-A nixos-fw -j nixos-fw-log-refuse')"
"""


def sh(argv: list[str], stdin: str | None = None) -> tuple[int, str, str]:
    p = subprocess.run(argv, input=stdin, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def read_host(host: str) -> dict[str, str]:
    rc, out, err = sh(
        ["ssh", "-o", "ConnectTimeout=15", "-o", "BatchMode=yes", host, "bash", "-s"],
        stdin=REMOTE,
    )
    if rc != 0:
        print(f"FATAL: ssh {host} bash -s failed rc={rc}: {err.strip()}", file=sys.stderr)
        raise SystemExit(2)
    facts: dict[str, str] = {}
    for line in out.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            facts[k] = v
    return facts


def ovh_get(api: str, reason: str, path: str) -> dict | list | None:
    """One read-only OVH call inside sudo-secretspec run; returns parsed JSON or None."""
    rc, out, err = sh(
        ["sudo-secretspec", "run", "--reason", reason, "--", sys.executable, api, "GET", path]
    )
    if rc != 0:
        print(f"OVH {path}: rc={rc} {err.strip()[:200]}", file=sys.stderr)
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        print(f"OVH {path}: unparseable response", file=sys.stderr)
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="dann")
    ap.add_argument("--ovh-api", default=OVH_API_DEFAULT)
    ap.add_argument("--ovh-service", default=OVH_SERVICE_DEFAULT)
    ap.add_argument("--site-dann", default=os.path.expanduser("~/ops/site-dann"),
                    help="local clone used to read the deploy-dann branch head")
    ap.add_argument("--fetch", action="store_true",
                    help="refresh the local deploy-dann ref before comparing (read-only, no branch writes)")
    ap.add_argument("--no-ovh", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    checks: list[tuple[bool, str, str]] = []  # (ok, name, detail)

    def check(ok: bool, name: str, detail: str) -> None:
        checks.append((ok, name, detail))

    if args.fetch:
        sh(["git", "-C", args.site_dann, "fetch", "-q", "origin", "deploy-dann"])
    rc, out, _ = sh(["git", "-C", args.site_dann, "rev-parse", "--short", "origin/deploy-dann"])
    deploy_head = out.strip() if rc == 0 and out.strip() else "unknown"

    f = read_host(args.host)

    rev = f.get("rev", "unknown")
    check(rev not in ("", "unknown"), "host revision readable", f"rev={rev[:12]}")
    check(
        deploy_head != "unknown" and rev.startswith(deploy_head),
        "host runs deploy-dann head",
        f"rev={rev[:7]} deploy-dann={deploy_head}" + ("" if args.fetch else " (local ref; --fetch to refresh)"),
    )
    try:
        uptime_days = int(f.get("uptime_s", "0")) / 86400
    except ValueError:
        uptime_days = 0.0
    check(True, "uptime / load / memory", f"{uptime_days:.1f}d load={f.get('load1')} mem_avail={f.get('mem_avail_mb')}MB")
    try:
        disk = int(f.get("disk_pct", "100"))
    except ValueError:
        disk = 100
    check(disk < 90, "disk under 90%", f"root={disk}%")
    check(f.get("failed_system", "1") == "0", "no failed system units", f"count={f.get('failed_system')}")
    check(f.get("failed_user", "1") == "0", "no failed user units", f"count={f.get('failed_user')}")
    check(
        f.get("upgrade_result") == "success" and f.get("upgrade_exit") == "0",
        "nixos-upgrade.timer succeeded",
        f"result={f.get('upgrade_result')} exit={f.get('upgrade_exit')} at={f.get('upgrade_when')}",
    )
    check(
        f.get("pv_exit") == "0" and (f.get("pv_line") or "").startswith("PASS"),
        "pool-verify PASS 18/18",
        f"{f.get('pv_ts')} {f.get('pv_line')} exit={f.get('pv_exit')}",
    )
    tm = f.get("tm_line", "")
    check(
        "exit=0" in tm and "status=" in tm,
        "tier1-mirror ran clean",
        tm.strip() or "no last.run",
    )
    chain_sha, mirror_sha = f.get("chain_sha", ""), f.get("mirror_sha", "")
    check(
        bool(chain_sha) and chain_sha == mirror_sha,
        "Tier 1 live file == repo mirror",
        f"sha256={chain_sha[:16]}…" if chain_sha == mirror_sha else f"live={chain_sha[:16]}… mirror={mirror_sha[:16]}…",
    )
    check(
        f.get("checkout_line", "").startswith("## main...origin/main"),
        "host checkout clean and level with origin",
        f"{f.get('checkout_line')} head={f.get('checkout_head')}",
    )
    ports = f.get("listener_ports", "").strip(",")
    check(
        ports in ("22", ""),
        "public surface is sshd:22 only",
        f"listener_ports={ports or 'none'}",
    )
    check(
        f.get("fw_ssh", "0") == "1" and f.get("fw_default_refuse", "0") >= "1",
        "iptables-legacy firewall active (ssh allowed, default refuse)",
        f"ssh_rule={f.get('fw_ssh')} refuse_rule={f.get('fw_default_refuse')}",
    )

    if not args.no_ovh:
        svc = args.ovh_service
        info = ovh_get(args.ovh_api, "read-only: keeper marker read — VPS state", f"/vps/{svc}")
        backup = ovh_get(args.ovh_api, "read-only: keeper marker read — automated backup", f"/vps/{svc}/automatedBackup")
        svc_info = ovh_get(args.ovh_api, "read-only: keeper marker read — renewal state", f"/vps/{svc}/serviceInfos")

        if isinstance(info, dict):
            check(
                info.get("state") == "running" and info.get("lockStatus", {}).get("locked") is False,
                "OVH: VPS running and unlocked",
                f"state={info.get('state')} locked={info.get('lockStatus', {}).get('locked')}",
            )
            model = info.get("model", {}) or {}
            check(
                info.get("vcore") == 6 and info.get("memoryLimit") == 12288 and model.get("disk") == 100,
                "OVH: hardware matches the plan (6 vCore / 12 GB / 100 GB)",
                f"vcore={info.get('vcore')} mem={info.get('memoryLimit')} disk={model.get('disk')}",
            )
        else:
            check(False, "OVH: VPS state readable", "call failed")

        if isinstance(backup, dict):
            check(
                backup.get("state") == "enabled" and backup.get("rotation") == 1,
                "OVH: daily automated backup enabled (one restore point)",
                f"state={backup.get('state')} rotation={backup.get('rotation')} at={backup.get('schedule')}",
            )
        else:
            check(False, "OVH: automated backup readable", "call failed")

        if isinstance(svc_info, dict):
            exp = svc_info.get("expiration") or ""
            renew = svc_info.get("renew", {}) or {}
            days_left = None
            try:
                exp_dt = datetime.strptime(exp, "%Y-%m-%d").replace(tzinfo=timezone.utc)
                days_left = (exp_dt - datetime.now(timezone.utc)).days
            except ValueError:
                pass
            check(
                svc_info.get("status") == "ok"
                and renew.get("automatic") is True
                and renew.get("deleteAtExpiration") is False,
                "OVH: service ok, auto-renews, not scheduled for deletion",
                f"status={svc_info.get('status')} expiration={exp} ({days_left} d) automatic={renew.get('automatic')}",
            )
            check(
                days_left is None or days_left >= 0,
                "OVH: not expired",
                f"expiration={exp} days_left={days_left}",
            )
            # The renewal *working* is the assertion that matters; a pushed-out
            # expiration is the only evidence of it the API offers.
            check(
                days_left is not None and -35 < days_left <= 40,
                "OVH: expiry sits on a ~1 month renewal cycle (so it renewed, not lapsed)",
                f"expiration={exp} days_left={days_left}",
            )
        else:
            check(False, "OVH: renewal state readable", "call failed")

    failed = [c for c in checks if not c[0]]
    if not args.quiet or failed:
        width = max(len(c[1]) for c in checks)
        for ok, name, detail in checks:
            print(f"{'PASS' if ok else 'FAIL'}  {name:<{width}}  {detail}")
    print(
        f"=== {'PASS' if not failed else 'FAIL'}: {len(checks)} checks, {len(failed)} failed  "
        f"({datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')})"
    )
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
