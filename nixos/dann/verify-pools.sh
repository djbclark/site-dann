#!/usr/bin/env bash
# verify-pools.sh — prove the five gifted AI pools on dann.dclark.us are live.
#
# Run ON the host as the hermes service user. The gateway's .env is
# 0600 hermes:hermes, so a `dann` CLI call dies with PermissionError; and
# /run/secrets/<NAME> is 0400 root, which is why the secret check falls back to
# .env when it cannot use passwordless sudo.
#
# Run the DEPLOYED copy, never an scp'd /tmp one: environment.etc installs this exact file at
# /etc/pool-verify/verify-pools.sh on every activation, so a manual run exercises the same bytes
# the timer runs and cannot drift from the repo.
#
#   sudo -n -u hermes env HOME=/var/lib/hermes HERMES_HOME=/var/lib/hermes/.hermes \
#     HERMES_MANAGED=true PATH=/run/current-system/sw/bin bash /etc/pool-verify/verify-pools.sh
#
# Hygiene: no key is printed, none is passed in argv, none is written anywhere.
# Only a key's byte length is read, and the NAME= prefix is compared in a
# stream: a file whose first line is not `NAME=value` yields no value byte at
# all, because at most ${#name}+1 bytes are read and never captured.
#
# Expected lengths are not in this file. They are not a secret either: a sops ciphertext is
# exactly as long as its plaintext, so nixos/dann/secrets/pools.yaml in this same public repo
# already publishes them. They stay out of the repo because they measure one host at one time,
# not because knowing them helps anyone. Supply them as NAME:bytes lines (the byte size of the
# whole `NAME=value` line — the stat size of /run/secrets/<NAME>, and the .env line length) and
# the script compares them too:
#
#   POOL_EXPECT=~/.config/dann/pool-expectations bash verify-pools.sh
#
# If POOL_EXPECT is set the file must be readable and non-empty, or the run fails with its own
# EXPECT line (path, mode, owner; never contents) instead of silently skipping the length check.
#
# Exit: 0 everything passed, 1 something failed.
#
# POOL_VERIFY_NO_SUDO=1 skips the /run/secrets branch entirely instead of probing it. Set it
# wherever this runs as a user with no sudo rule (the daily timer runs as `hermes`): each probe
# is otherwise a denied sudo attempt in the auth journal, five a day, which reads like a real
# denial and trains people to ignore the real ones. The .env branch carries the same lines.
set -u
export PATH="$PATH:/run/current-system/sw/bin"

SUDO="sudo -n"
if [ "${POOL_VERIFY_NO_SUDO:-0}" = 1 ]; then SUDO=""; fi
EXPECT_FILE="${POOL_EXPECT:-}"
fails=0
checks=0

# The run must perform exactly this many checks, or it fails: deleting a `pool` line, a secret
# name or the sops probe below then turns the run red instead of leaving it quietly green. Checks:
# 1 gateway unit + 1 sops probe + 5 secrets + 6 pools (5 named + the default chain) = 13, plus one
# more when POOL_EXPECT is set (the expect file itself). ADDING A POOL: add it to poolSecrets and
# to the providers/fallback_providers in nixos/dann/hermes.nix, then here: the secret NAME in
# `secret_report`'s list, a `pool` line under "=== pools", and bump this number.
EXPECTED_BASE_CHECKS=13

# An expect file that was asked for (POOL_EXPECT set) but cannot be used is a failure, never "no
# expectations": an unreadable or empty file would otherwise turn the length check off silently.
expect_usable() { [ -n "$EXPECT_FILE" ] && [ -r "$EXPECT_FILE" ] && [ -s "$EXPECT_FILE" ]; }

# Mode and owner of a path, never its contents. GNU stat, then BSD stat for a run on the Mac.
describe_path() {
  stat -c '%A %U:%G' "$1" 2>/dev/null || stat -f '%Sp %Su:%Sg' "$1" 2>/dev/null || printf 'absent'
}

# Expected line length for NAME from $EXPECT_FILE, or empty.
expected_bytes() {
  expect_usable || return 0
  awk -F: -v k="$1" '$1 == k { gsub(/[^0-9]/, "", $2); print $2; exit }' "$EXPECT_FILE"
}

# Report one secret: present? right name prefix? right length? Never the value.
secret_report() {
  local name want got prefix src note
  # The same five names as `poolSecrets` in nixos/dann/hermes.nix (the source of truth); see
  # EXPECTED_BASE_CHECKS above for what to change together.
  for name in \
    OPENCODE_GO_API_KEY_DJBCLARK \
    OPENCODE_GO_API_KEY_TECHNOEUPHORA \
    CLINE_API_KEY \
    CLINE_PASS_KEY_2_TE \
    AWS_BEARER_TOKEN_BEDROCK
  do
    want=$(expected_bytes "$name")
    got=""
    prefix=""
    src=""
    note=""
    checks=$((checks + 1))

    if [ -n "$SUDO" ] && $SUDO test -e "/run/secrets/$name" 2>/dev/null; then
      got=$($SUDO stat -c %s "/run/secrets/$name" 2>/dev/null)
      # Compare the NAME= prefix as a stream: no value byte is captured, so a
      # file that is not a `NAME=value` line cannot leak into a variable, a
      # note or stdout. Reading ${#name}+1 bytes of a proper line stops at '='.
      if $SUDO head -c $(( ${#name} + 1 )) "/run/secrets/$name" 2>/dev/null \
         | cmp -s - <(printf '%s=' "$name"); then
        prefix=$name
      else
        prefix=""
      fi
      src="/run/secrets"
    elif [ -n "${HERMES_HOME:-}" ] && [ -r "$HERMES_HOME/.env" ]; then
      # What the module's activation appended; length of the whole line.
      got=$(awk -F= -v k="$name" '$1 == k { print length($0); exit }' "$HERMES_HOME/.env")
      prefix=$(awk -F= -v k="$name" '$1 == k { print $1; exit }' "$HERMES_HOME/.env")
      src=".env"
    fi

    if [ -z "$got" ]; then
      printf 'SECRET  %-32s FAIL  absent (no /run/secrets entry, no .env line)\n' "$name"
      fails=$((fails + 1))
      continue
    fi

    case "$got" in *[!0-9]*) note="unreadable length '$got'" ;; esac
    if [ -z "$note" ] && [ "$prefix" != "$name" ]; then
      note="first line is not '$name=...'"
    fi
    if [ -z "$note" ] && [ "$got" -lt 48 ]; then
      note="suspiciously short ($got bytes)"
    fi
    if [ -z "$note" ] && [ "$got" -gt 4096 ]; then
      note="suspiciously long ($got bytes)"
    fi
    if [ -z "$note" ] && [ -n "$want" ] && [ "$got" != "$want" ]; then
      note="$got bytes, expected $want"
    fi

    if [ -z "$note" ]; then
      printf 'SECRET  %-32s ok    %4s bytes  via %s\n' "$name" "$got" "$src"
    else
      printf 'SECRET  %-32s FAIL  %s\n' "$name" "$note"
      fails=$((fails + 1))
    fi
  done
}

# `--provider` does NOT exempt a call from `fallback_providers`: on a 401/403, a rate limit or a
# missing key hermes moves to the next pool in the chain and still exits 0 with the token, so rc
# and token alone cannot tell which pool answered. Hermes logs every such switch to agent.log, so a
# call that named a provider is a PASS only if no new line below appeared while it ran.
# The strings are the ones hermes-agent writes at the revision pinned in nixos/flake.lock
# (86d6689): "Fallback activated: ..." and "Fallback activated after empty responses" (mid-turn,
# agent/chat_completion_helpers.py, turn_empty_response.py), "... refused for billing/credits ..."
# (the same switch when the reason is billing), "Primary provider ... Falling through to fallback"
# (startup: the primary's credentials do not resolve; hermes_cli/cli_agent_setup_mixin.py) and
# "attempting fallback" (empty-response retries exhausted). Re-check them when the pin moves.
FALLBACK_RE='Fallback activated|Falling through to fallback|refused for billing/credits|attempting fallback'
AGENT_LOG="${HERMES_HOME:-$HOME/.hermes}/logs/agent.log"

# Bytes in agent.log (0 if it does not exist yet), or empty if it exists but cannot be read.
agent_log_size() {
  [ -e "$AGENT_LOG" ] || { printf 0; return 0; }
  wc -c < "$AGENT_LOG" 2>/dev/null | tr -d ' '
}

# Did a fallback line appear after byte offset $1? Prints nothing, never a log line (the log can
# carry prompt text). Returns 0 = fallback seen, 1 = none, 2 = log unreadable or gone.
fallback_since() {
  local before=$1 after
  after=$(agent_log_size)
  [ -n "$after" ] && [ -r "$AGENT_LOG" ] || return 2
  # A log that shrank was rotated during the call: scan what is there now.
  [ "$after" -lt "$before" ] && before=0
  tail -c +$((before + 1)) "$AGENT_LOG" 2>/dev/null | grep -Eq "$FALLBACK_RE"
}

# One pool: a real completion through that provider, not a /models probe.
# pool LABEL PROVIDER MODEL   (PROVIDER empty = exercise the default chain, where a fallback is
# the chain doing its job and is not held against it)
pool() {
  local label=$1 provider=${2:-} model=${3:-} want args=() out rc first before="" fb=1 proof=""
  [ -n "$provider" ] && args+=(--provider "$provider")
  [ -n "$model" ] && args+=(--model "$model")
  if [ -n "$provider" ]; then want="VERIFY-OK"; else want="DEFAULT-OK"; fi
  if [ -n "$provider" ]; then
    before=$(agent_log_size)
    [ -n "$before" ] || proof="cannot read $AGENT_LOG ($(describe_path "$AGENT_LOG")), so a fallback switch cannot be ruled out"
  fi

  out=$(timeout 240 hermes chat -Q -q "Reply with exactly the token $want and nothing else." \
    --oneshot "${args[@]}" 2>&1)
  rc=$?
  first=$(printf '%s' "$out" | tr -s '\n ' ' ' | cut -c1-200)
  checks=$((checks + 1))

  if [ -n "$provider" ] && [ -z "$proof" ]; then
    fallback_since "$before"
    fb=$?
    [ $fb -eq 2 ] && proof="cannot read $AGENT_LOG after the call, so a fallback switch cannot be ruled out"
  fi

  if [ $rc -ne 0 ] || ! printf '%s' "$out" | grep -q "$want"; then
    printf 'POOL    %-18s FAIL  rc=%s  %s\n' "$label" "$rc" "$first"
    fails=$((fails + 1))
  elif [ -n "$proof" ]; then
    printf 'POOL    %-18s FAIL  %s\n' "$label" "$proof"
    fails=$((fails + 1))
  elif [ -n "$provider" ] && [ $fb -eq 0 ]; then
    printf 'POOL    %-18s FAIL  answered, but hermes switched to a fallback pool during the call: %s did not serve it\n' "$label" "$provider"
    fails=$((fails + 1))
  else
    printf 'POOL    %-18s PASS  %s\n' "$label" "${model:-default chain}"
  fi
}

# The unit name differs between module versions (`hermes-agent.service` today);
# report whichever one exists rather than guessing.
unit_state() {
  local u
  for u in hermes-agent hermes; do
    if systemctl cat "$u" >/dev/null 2>&1; then
      printf '%s %s/%s' "$u" "$(systemctl is-active "$u" 2>/dev/null)" "$(systemctl is-enabled "$u" 2>/dev/null)"
      return 0
    fi
  done
  printf 'no hermes unit found'
}

printf '=== %s on %s\n' "$(id -un)" "$(hostname)"
printf '=== hermes %s (%s)\n' "$(hermes --version 2>&1 | head -1)" "$(command -v hermes || echo MISSING)"
unit=$(unit_state)
case "$unit" in
  *" active/"*) printf 'UNIT    %-18s ok    %s\n' hermes-gateway "$unit" ;;
  *)
    printf 'UNIT    %-18s FAIL  %s\n' hermes-gateway "$unit"
    fails=$((fails + 1))
    ;;
esac
checks=$((checks + 1))

# sops-nix places /run/secrets/sops_probe on every activation (configuration.nix, "sops_probe"), so
# its absence or emptiness means decryption broke. Only its existence and size are tested: the
# secrets directory is traversable by any user but the files are not readable by `hermes`, and
# `test -e/-s` needs no read permission (no sudo, no content). It cannot see a probe left over from
# an older generation; a failed activation is the nixos-upgrade unit's to report.
checks=$((checks + 1))
if [ -s /run/secrets/sops_probe ]; then
  printf 'SOPS    %-32s ok    present, non-empty\n' sops_probe
elif [ -e /run/secrets/sops_probe ]; then
  printf 'SOPS    %-32s FAIL  present but empty\n' sops_probe
  fails=$((fails + 1))
else
  printf 'SOPS    %-32s FAIL  absent: sops-nix did not place its probe\n' sops_probe
  fails=$((fails + 1))
fi

expected_checks=$EXPECTED_BASE_CHECKS
if [ -n "$EXPECT_FILE" ]; then
  expected_checks=$((expected_checks + 1))
  checks=$((checks + 1))
  if expect_usable; then
    printf '=== expected lengths from %s\n' "$EXPECT_FILE"
  else
    printf 'EXPECT  %-32s FAIL  supplied but unusable (%s; readable by %s: %s, non-empty: %s): the length check would be skipped\n' \
      "$EXPECT_FILE" "$(describe_path "$EXPECT_FILE")" "$(id -un)" \
      "$([ -r "$EXPECT_FILE" ] && echo yes || echo no)" "$([ -s "$EXPECT_FILE" ] && echo yes || echo no)"
    fails=$((fails + 1))
  fi
else
  printf '=== expected lengths not supplied: presence, shape and completion only\n'
fi

printf '=== secrets\n'
secret_report

printf '=== pools\n'
pool go-djbc          opencode-go-djbc         deepseek-v4.1-flash
pool go-technoeuphora opencode-go-technoeuphora deepseek-v4.1-flash
pool cline-djbclark   cline-djbclark           cline2-pass/deepseek-v4-flash
pool cline-techno     cline-technoeuphora      cline2-pass/deepseek-v4-flash
pool bedrock-scout    bedrock                  us.meta.llama4-scout-17b-instruct-v1:0
pool default-chain    ""                       ""

if [ "$checks" -ne "$expected_checks" ]; then
  printf 'COUNT   %-32s FAIL  ran %d checks, expected %d: a pool or secret was dropped or added without updating EXPECTED_BASE_CHECKS\n' \
    checks "$checks" "$expected_checks"
  fails=$((fails + 1))
fi

if [ $fails -eq 0 ]; then
  printf '=== PASS: %d checks, none failed\n' "$checks"
  exit 0
fi
printf '=== FAIL: %d checks, %d failed\n' "$checks" "$fails"
exit 1
