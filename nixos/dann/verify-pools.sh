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
# Only a key's byte length and the variable name before the first '=' are read.
#
# Expected lengths are deliberately NOT in this public repo. Supply them
# privately as NAME:bytes lines (the byte size of the whole `NAME=value` line —
# the stat size of /run/secrets/<NAME>, and the .env line length) and the
# script compares them too:
#
#   POOL_EXPECT=~/.config/dann/pool-expectations bash verify-pools.sh
#
# Exit: 0 everything passed, 1 something failed.
set -u
export PATH="$PATH:/run/current-system/sw/bin"

SUDO="sudo -n"
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

    if $SUDO test -e "/run/secrets/$name" 2>/dev/null; then
      got=$($SUDO stat -c %s "/run/secrets/$name" 2>/dev/null)
      # bytes up to the first '=' are the variable name: not a secret
      prefix=$($SUDO head -c 200 "/run/secrets/$name" 2>/dev/null | awk -F= 'NR == 1 { print $1 }')
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
      note="line starts with '$prefix', not '$name'"
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

printf '=== %s on %s\n' "$(id -un)" "$(hostname)"
printf '=== hermes %s (%s)\n' "$(hermes --version 2>&1 | head -1)" "$(command -v hermes || echo MISSING)"
printf '=== unit %s\n' "$(systemctl is-active hermes 2>/dev/null || echo '?')"
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
