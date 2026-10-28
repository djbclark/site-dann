# pool-verify — the daily proof that dann.dclark.us can still do agent work.
#
# The five gifted AI pools, the five secrets and the hermes gateway are the only things this host
# exists for, and until 2026-10-28 nothing checked them between manual runs. This module makes
# verify-pools.sh a daily systemd oneshot and keeps its last result on disk where another machine
# can read it:
#
#   /var/lib/pool-verify/last        the full report, timestamped
#   /var/lib/pool-verify/last.exit   the exit status of the last run ("0" = everything passed)
#
# The report is also in the journal (`journalctl -u pool-verify`). It is NOT an alerting channel:
# the host has no messaging platform configured by design (`hermes.nix`), so the pager lives
# outside — djbclark's `fleet-watch dann` reads these files over ssh and is the only thing that
# speaks. Keeping the two roles apart is deliberate: the timer says what is true, fleet-watch
# decides when it is worth waking someone.
{ config, lib, pkgs, ... }:

let
  # Where the harness and its last result live. StateDirectory makes this hermes-owned, which is
  # all the runner needs and all `dann` needs to read.
  stateDir = "/var/lib/pool-verify";

  # The harness is installed from this repo (./verify-pools.sh), so the file the timer runs is
  # byte-for-byte the one the runbook tells a human to run — no second copy to drift.
  # environment.etc copies at activation time and is not a store path, so the runner reads it from
  # there; that also means an operator can read the exact script the timer runs.
  harnessOut = "/etc/pool-verify/verify-pools.sh";

  # Wrap it: keep the report for the journal AND for disk, and always record the exit status,
  # including on failure (a bare oneshot leaves the caller to guess).
  runner = pkgs.writeShellScript "pool-verify-run" ''
    set -u
    report="$(mktemp)"
    trap 'rm -f "$report"' EXIT

    # Optional private expectations (exact NAME=value line lengths). Never in this public repo;
    # drop the file in place and the harness's length check starts working with no rebuild.
    [ -r /etc/pool-verify/expect ] && export POOL_EXPECT=/etc/pool-verify/expect

    rc=0
    ${pkgs.bash}/bin/bash ${harnessOut} >"$report" 2>&1 || rc=$?

    # The journal gets the whole report.
    cat "$report"

    # And so does disk, atomically, with a timestamp a human or a probe can read.
    {
      printf '=== pool-verify %s exit=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$rc"
      cat "$report"
    } > "${stateDir}/last.new"
    mv -f "${stateDir}/last.new" "${stateDir}/last"
    printf '%s\n' "$rc" > "${stateDir}/last.exit.new"
    mv -f "${stateDir}/last.exit.new" "${stateDir}/last.exit"

    exit "$rc"
  '';
in
{
  environment.etc."pool-verify/verify-pools.sh" = {
    source = ./verify-pools.sh;
    mode = "0555";
  };

  systemd.services.pool-verify = {
    description = "Verify the five AI pools, their secrets and the Hermes gateway";
    # After the gateway exists (no point in racing its activation) and once the network is up:
    # every check is a real HTTPS completion.
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "hermes-agent.service" ];

    serviceConfig = {
      Type = "oneshot";
      # The gateway's .env is hermes:hermes, so the service user is `hermes` and no sudo rule is
      # involved anywhere. `dann` would work too (it is in the hermes group) but this is the
      # identity the harness was verified under.
      User = "hermes";
      Group = config.services.hermes-agent.group;
      ExecStart = runner;
      StateDirectory = "pool-verify";
      StateDirectoryMode = "0755";
      # Six real completions with a 240 s cap each; 30 min is generous and still bounded.
      TimeoutStartSec = "1800";
      # A failed verification is information, not a service fault: it must not be restarted in a
      # loop (that would burn pool quota) and it must not mark the unit as needing rescue.
      Restart = "no";
      # Keep the last result readable even if the pool keys are what broke.
      UMask = "0022";
      Environment = [
        "HOME=/var/lib/hermes"
        "HERMES_HOME=/var/lib/hermes/.hermes"
        "HERMES_MANAGED=true"
        "PATH=/run/current-system/sw/bin"
      ];
    };
  };

  systemd.timers.pool-verify = {
    description = "Daily verification of dann's AI pools and gateway";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 05:20 UTC, after the 04:00+45min unattended upgrade window, so a verification never races
      # an activation that is restarting the gateway underneath it.
      OnCalendar = "*-*-* 05:20:00";
      RandomizedDelaySec = "30min";
      # A host that was off for the slot still gets today's answer shortly after it comes up.
      Persistent = true;
      Unit = "pool-verify.service";
    };
  };
}
