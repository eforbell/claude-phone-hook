#!/usr/bin/env bash
# Claude Code Hook: Push notification + optional remote approval via brrr.now
#
# SETUP:
#   1. Install brrr app on iPhone, get your secret
#   2. Set BRRR_SECRET in your env (or hardcode below)
#   3. For remote approval: ensure relay.sh is running and tailscale is connected
#      RELAY_URL is auto-detected from tailscale if not set explicitly
#   4. Add to ~/.claude/settings.json (see settings-snippet.json)
#
# MODES:
#   - Notification only (REMOTE_APPROVE=0): sends push, falls through to normal prompt
#   - Remote approval (REMOTE_APPROVE=1, default): sends push with tap-to-approve link,
#     polls for response, returns decision to Claude Code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Config (override via env) ─────────────────────────────────────────────────
BRRR_SECRET="${BRRR_SECRET:-}"                    # REQUIRED: your brrr.now secret
BRRR_API="https://api.brrr.now/v1"
REMOTE_APPROVE="${REMOTE_APPROVE:-1}"              # 1 = remote approval, 0 = notify only
RELAY_URL="${RELAY_URL:-}"                         # Auto-detected from tailscale if empty
RELAY_PORT="${RELAY_PORT:-9876}"                    # Port for local relay server
POLL_INTERVAL="${POLL_INTERVAL:-2}"                 # Seconds between polls
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"                 # Max seconds to wait (5 min)
RESPONSE_DIR="${SCRIPT_DIR}/.responses"
SOUND="${BRRR_SOUND:-default}"
LOG_FILE="${SCRIPT_DIR}/notify.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

log "── Hook invoked ──"
log "Args: $*"
log "Env: BRRR_SECRET=${BRRR_SECRET:+(set)} REMOTE_APPROVE=$REMOTE_APPROVE RELAY_URL=${RELAY_URL:-(empty)} RELAY_PORT=$RELAY_PORT"
log "Stdin follows:"
# We need to capture stdin early since we can only read it once — move the cat up
INPUT=$(cat)
log "$INPUT"

# ── Auto-detect Tailscale hostname if RELAY_URL not set ───────────────────────
if [[ -z "$RELAY_URL" && "$REMOTE_APPROVE" == "1" ]]; then
  log "Tailscale auto-detect: looking for tailscale binary..."
  if command -v tailscale &>/dev/null; then
    TS_BIN=$(command -v tailscale)
    log "Tailscale binary found at: $TS_BIN"
    TS_RAW=$($TS_BIN status --json 2>&1 || true)
    log "Tailscale status --json output (first 500 chars): ${TS_RAW:0:500}"
    TS_FQDN=$(echo "$TS_RAW" | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//')
    log "Parsed TS_FQDN: ${TS_FQDN:-(empty)}"
    if [[ -n "$TS_FQDN" ]]; then
      RELAY_URL="http://${TS_FQDN}:${RELAY_PORT}"
      log "RELAY_URL set to: $RELAY_URL"
    fi
  else
    log "Tailscale binary NOT found in PATH: $PATH"
  fi

  if [[ -z "$RELAY_URL" ]]; then
    log "RELAY_URL still empty — falling back to notification-only"
    REMOTE_APPROVE=0
  fi
fi
# ──────────────────────────────────────────────────────────────────────────────

if [[ -z "$BRRR_SECRET" ]]; then
  log "BRRR_SECRET not set — falling back to ask"
  echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}' 2>/dev/null
  exit 0
fi

log "Parsing hook input..."
# Parse hook input (already captured from stdin above)
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // empty' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
log "Parsed: event=$HOOK_EVENT tool=$TOOL_NAME session=$SESSION_ID"

# Build notification content
TITLE="Claude Code needs you"
SUBTITLE=""
BODY=""
case "$HOOK_EVENT" in
  PermissionRequest)
    if [[ -n "$TOOL_NAME" ]]; then
      SUBTITLE="Tool: $TOOL_NAME"
      BODY=$(echo "$TOOL_INPUT" | head -c 200 || true)
    else
      SUBTITLE="Permission required"
      BODY="Claude is waiting for your approval"
    fi
    ;;
  Notification)
    SUBTITLE="Input needed"
    BODY="Claude is waiting for your response"
    ;;
  *)
    SUBTITLE="Attention needed"
    BODY="$HOOK_EVENT"
    ;;
esac
log "Notification content: title=$TITLE subtitle=$SUBTITLE body=${BODY:0:100}"

# ── Notification-only mode ────────────────────────────────────────────────────
if [[ "$REMOTE_APPROVE" != "1" ]]; then
  curl -sf -X POST "${BRRR_API}/${BRRR_SECRET}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n \
      --arg title "$TITLE" \
      --arg subtitle "$SUBTITLE" \
      --arg message "$BODY" \
      --arg sound "$SOUND" \
      '{title: $title, subtitle: $subtitle, message: $message, sound: $sound, "interruption-level": "time-sensitive"}'
    )" >/dev/null 2>&1 || true

  # Fall through to normal interactive prompt
  if [[ "$HOOK_EVENT" == "PermissionRequest" ]]; then
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}'
  fi
  exit 0
fi

# ── Remote approval mode ─────────────────────────────────────────────────────
log "Entering remote approval mode"
mkdir -p "$RESPONSE_DIR"
REQUEST_ID="req_$(date +%s)_$$"
RESPONSE_FILE="${RESPONSE_DIR}/${REQUEST_ID}"

# Build the open_url that the notification tap will open
OPEN_URL="${RELAY_URL}/approve?id=${REQUEST_ID}&tool=${TOOL_NAME}&session=${SESSION_ID}"
log "open_url=$OPEN_URL"
log "Sending brrr push to ${BRRR_API}/***..."

# Send push with tap-to-approve link
BRRR_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${BRRR_API}/${BRRR_SECRET}" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
    --arg title "$TITLE" \
    --arg subtitle "$SUBTITLE" \
    --arg message "$BODY" \
    --arg sound "$SOUND" \
    --arg open_url "$OPEN_URL" \
    '{title: $title, subtitle: $subtitle, message: $message, sound: $sound, open_url: $open_url, "interruption-level": "time-sensitive"}'
  )" 2>&1 || true)
log "brrr response: $BRRR_RESPONSE"

log "Polling for response at $RESPONSE_FILE (timeout=${POLL_TIMEOUT}s)..."

# Poll for response file (written by relay server)
ELAPSED=0
while [[ $ELAPSED -lt $POLL_TIMEOUT ]]; do
  if [[ -f "$RESPONSE_FILE" ]]; then
    DECISION=$(cat "$RESPONSE_FILE")
    rm -f "$RESPONSE_FILE"

    case "$DECISION" in
      allow)
        log "Decision: allow"
        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        ;;
      deny)
        log "Decision: deny"
        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from phone"}}}'
        ;;
      *)
        # Freeform message — deny with the message as reason so Claude sees it
        log "Decision: deny with message: $DECISION"
        ESCAPED=$(echo "$DECISION" | jq -Rs '.')
        echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":${ESCAPED}}}}"
        ;;
    esac
    exit 0
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Timeout — fall back to interactive prompt
echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}'
exit 0
