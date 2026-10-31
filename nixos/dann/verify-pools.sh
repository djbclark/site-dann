#!/usr/bin/env bash
# verify-pools.sh — prove the five gifted AI pools on dann.dclark.us are live.
#
# Run ON the host as the hermes service user. The gateway's .env is
# 0600 hermes:hermes, so a `dann` CLI call dies with PermissionError; and
# /run/secrets/<NAME> is 0400 root, which is why the secret check falls back to
# .env when it cannot use passwordless sudo.
#
#   sudo -n -u hermes env HOME=/var/lib/hermes HERMES_HOME=/var/lib/hermes/.hermes \
#     HERMES_MANAGED=true PATH=/run/current-system/sw/bin bash /tmp/verify-pools.sh
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

# Expected line length for NAME from $EXPECT_FILE, or empty.
expected_bytes() {
  [ -n "$EXPECT_FILE" ] && [ -r "$EXPECT_FILE" ] || return 0
  awk -F: -v k="$1" '$1 == k { gsub(/[^0-9]/, "", $2); print $2; exit }' "$EXPECT_FILE"
}

# Report one secret: present? right name prefix? right length? Never the value.
secret_report() {
  local name want got prefix src note
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

# One pool: a real completion through that provider, not a /models probe.
# pool LABEL PROVIDER MODEL   (PROVIDER empty = exercise the default chain)
pool() {
  local label=$1 provider=${2:-} model=${3:-} want args=() out rc first
  [ -n "$provider" ] && args+=(--provider "$provider")
  [ -n "$model" ] && args+=(--model "$model")
  if [ -n "$provider" ]; then want="VERIFY-OK"; else want="DEFAULT-OK"; fi

  out=$(timeout 240 hermes chat -Q -q "Reply with exactly the token $want and nothing else." \
    --oneshot "${args[@]}" 2>&1)
  rc=$?
  first=$(printf '%s' "$out" | tr -s '\n ' ' ' | cut -c1-200)
  checks=$((checks + 1))

  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "$want"; then
    printf 'POOL    %-18s PASS  %s\n' "$label" "${model:-default chain}"
  else
    printf 'POOL    %-18s FAIL  rc=%s  %s\n' "$label" "$rc" "$first"
    fails=$((fails + 1))
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
if [ -n "$EXPECT_FILE" ]; then
  printf '=== expected lengths from %s\n' "$EXPECT_FILE"
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

if [ $fails -eq 0 ]; then
  printf '=== PASS: %d checks, none failed\n' "$checks"
  exit 0
fi
printf '=== FAIL: %d checks, %d failed\n' "$checks" "$fails"
exit 1
