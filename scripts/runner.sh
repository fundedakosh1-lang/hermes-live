#!/usr/bin/env bash
# runner.sh — executed inside a GitHub Actions job (workflow: hermes-live).
# Keeps Hermes alive for RUN_MINUTES, snapshots the brain to the private repo,
# then dispatches its successor job before the 6h runner cap hits.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${RUN_LOG:-/tmp/hermes-gateway.log}"
BRAIN_DIR="${BRAIN_DIR:-/opt/hermes-brain}"
INTERVAL="${SNAPSHOT_INTERVAL:-600}"
RUN_SECONDS=$(( ${RUN_MINUTES:-315} * 60 ))

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

log "== hermes-live start =="
: "${BRAIN_REPO:?BRAIN_REPO required}" "${BRAIN_TOKEN:?BRAIN_TOKEN required}"

# 1. restore state
mkdir -p "$HERMES_HOME"
bash "$HERE/brain.sh" fetch "$BRAIN_DIR" || log "WARN: brain fetch failed (starting fresh)"
if [[ -f "$BRAIN_DIR/state.tar.gz" ]]; then
  bash "$HERE/brain.sh" restore "$BRAIN_DIR/state.tar.gz" || log "WARN: restore failed"
fi

# 2. install hermes
export PATH="$HOME/.local/bin:$PATH"
if ! command -v hermes >/dev/null 2>&1; then
  log "installing hermes..."
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v hermes >/dev/null 2>&1 || { log "FATAL: hermes not installed"; exit 1; }
log "hermes ready"

# 3. start gateway
start_gateway() {
  nohup hermes gateway run --replace >>"$LOG" 2>&1 &
  sleep 20
  if pgrep -f "hermes gateway" >/dev/null; then
    log "gateway up"
  else
    log "WARN: gateway not detected, see $LOG"
  fi
}
start_gateway

# 4. live loop
start=$(date +%s); last_snap=$start; restarts=0
while :; do
  sleep 60
  now=$(date +%s); elapsed=$((now - start))
  if ! pgrep -f "hermes gateway" >/dev/null; then
    if (( restarts < 3 )); then
      restarts=$((restarts + 1)); log "gateway down -> restart $restarts"; start_gateway
    else
      log "FATAL: gateway down 3x, ending run early"; break
    fi
  fi
  if (( now - last_snap >= INTERVAL )); then
    last_snap=$now
    bash "$HERE/brain.sh" snapshot "$BRAIN_DIR" || log "WARN: snapshot failed"
  fi
  (( elapsed >= RUN_SECONDS )) && break
done

# 5. final snapshot, stop, dispatch successor
bash "$HERE/brain.sh" snapshot "$BRAIN_DIR" || log "WARN: final snapshot failed"
pkill -f "hermes gateway" 2>/dev/null || true
sleep 3
log "dispatching successor..."
code=$(curl -sS -o /tmp/dispatch.json -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $BRAIN_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/run.yml/dispatches" \
  -d '{"ref":"main"}' || echo "000")
log "dispatch HTTP $code"
head -c 300 /tmp/dispatch.json 2>/dev/null; echo
log "== hermes-live stop =="
