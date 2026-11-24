#!/usr/bin/env bash
# brain.sh — pack / restore / sync the Hermes "brain" (profile state).
#
# Usage:
#   brain.sh pack  [OUT.tar.gz]      snapshot $HERMES_HOME -> tar.gz
#   brain.sh restore TAR [DEST]      extract TAR into DEST (default $HERMES_HOME)
#   brain.sh fetch DIR               clone/pull the state repo into DIR
#   brain.sh snapshot DIR            fetch + pack + commit + push
#
# Env:
#   HERMES_HOME   profile dir (default ~/.hermes)
#   BRAIN_REPO    owner/name of the PRIVATE state repo
#   BRAIN_TOKEN   PAT with Contents:RW on BRAIN_REPO
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CMD="${1:-}"; shift 2>/dev/null || true

ITEMS=(
  config.yaml .env SOUL.md channel_directory.json spawn-ledger.json
  memories skills skins plugins platforms runtime state cron sessions plans kanban
  state.db state.db-wal state.db-shm
  kanban.db kanban.db-wal kanban.db-shm
  shared-state.db shared-state.db-wal shared-state.db-shm
  response_store.db response_store.db-wal response_store.db-shm
  runs_idempotency.db runs_idempotency.db-wal runs_idempotency.db-shm
)
TAR_EXCLUDES=(
  --exclude='*.lock' --exclude='gateway.sock' --exclude='gateway.pid'
  --exclude='__pycache__' --exclude='.git' --exclude='node_modules'
  --exclude='cache' --exclude='audio_cache' --exclude='image_cache'
  --exclude='logs' --exclude='backups' --exclude='pending_messages'
  --exclude='pairing' --exclude='auth.json' --exclude='*.sock' --exclude='*.pid'
)

present_items() {
  local f; for f in "${ITEMS[@]}"; do [[ -e "$HERMES_HOME/$f" ]] && printf '%s\n' "$f"; done
}

do_pack() {
  local out="${1:-hermes-brain.tar.gz}"
  local files=(); mapfile -t files < <(present_items)
  if [[ ${#files[@]} -eq 0 ]]; then echo "nothing to pack in $HERMES_HOME" >&2; return 1; fi
  tar -czf "$out" -C "$HERMES_HOME" "${TAR_EXCLUDES[@]}" "${files[@]}" || return 1
  echo "packed ${#files[@]} items -> $out ($(du -h "$out" | cut -f1))"
}

do_restore() {
  local tar="$1" dest="${2:-$HERMES_HOME}"
  [[ -f "$tar" ]] || { echo "no such archive: $tar" >&2; return 1; }
  mkdir -p "$dest"
  tar -xzf "$tar" -C "$dest" || return 1
  echo "restored $tar -> $dest"
}

askpass() {
  local f; f="$(mktemp)"
  cat > "$f" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) echo "x-access-token" ;;
  *Password*) echo "$BRAIN_TOKEN" ;;
esac
EOF
  chmod +x "$f"; echo "$f"
}

with_git_auth() { # sets GIT_ASKPASS for the duration of "$@"
  local ap; ap="$(askpass)"
  GIT_ASKPASS="$ap" GIT_TERMINAL_PROMPT=0 "$@"
  local rc=$?; rm -f "$ap"; return $rc
}

do_fetch() {
  local dir="$1"
  : "${BRAIN_REPO:?set BRAIN_REPO}" "${BRAIN_TOKEN:?set BRAIN_TOKEN}"
  if [[ -d "$dir/.git" ]]; then
    with_git_auth git -C "$dir" pull --rebase -q || with_git_auth git -C "$dir" reset --hard -q origin/HEAD
  else
    rm -rf "$dir"; mkdir -p "$(dirname "$dir")"
    with_git_auth git clone -q --depth 1 "https://github.com/${BRAIN_REPO}.git" "$dir"
  fi
}

do_snapshot() {
  local dir="$1"
  do_fetch "$dir" || return 1
  do_pack "$dir/state.tar.gz" || return 1
  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet; then echo "brain unchanged"; return 0; fi
  git -C "$dir" -c user.name=hermes -c user.email=hermes@localhost \
    commit -q -m "brain snapshot $(date -u +%FT%TZ)"
  with_git_auth git -C "$dir" push -q origin HEAD || return 1
  echo "brain pushed"
}

case "$CMD" in
  pack)     do_pack "$@" ;;
  restore)  do_restore "$@" ;;
  fetch)    do_fetch "$@" ;;
  snapshot) do_snapshot "$@" ;;
  *) echo "usage: brain.sh pack|restore|fetch|snapshot ..." >&2; exit 2 ;;
esac
