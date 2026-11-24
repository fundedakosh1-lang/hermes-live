#!/usr/bin/env bash
# setup.sh — one-time provisioning for the hermes-live 24/7 rig.
#
# Run it on your own machine (or in the Hermes container terminal):
#     bash setup.sh
# The PAT is typed interactively (hidden) and is never written to disk.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PUB="${PUBLIC_REPO:-hermes-live}"
PRIV="${BRAIN_REPO:-hermes-brain}"
if [[ -z "${HERMES_HOME:-}" ]]; then
  if [[ -f /opt/data/config.yaml ]]; then HERMES_HOME=/opt/data; else HERMES_HOME="$HOME/.hermes"; fi
fi

read -rp "GitHub owner/username [${GITHUB_OWNER:-}]: " in; OWNER="${in:-${GITHUB_OWNER:-}}"
read -rp "Public runner repo name [${PUB}]: " in; PUB="${in:-$PUB}"
read -rp "Private brain repo name [${PRIV}]: " in; PRIV="${in:-$PRIV}"
read -rsp "GitHub PAT (hidden input): " GH_PAT; echo
: "${OWNER:?owner required}" "${GH_PAT:?PAT required}"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

api() { curl -sS -H "Authorization: Bearer ${GH_PAT}" -H "Accept: application/vnd.github+json" "$@"; }

echo "== token check =="
user_json=$(api https://api.github.com/user) || { echo "token check failed"; exit 1; }
login=$(printf '%s' "$user_json" | jq -r '.login // empty' 2>/dev/null)
[[ -n "$login" ]] || { echo "could not read /user — is the PAT valid?"; exit 1; }
echo "authenticated as: $login"

create_repo() { # $1=name  $2=private(true|false)
  local body out
  body=$(printf '{"name":"%s","private":%s,"auto_init":false}' "$1" "$2")
  out=$(api -X POST https://api.github.com/user/repos -d "$body")
  if printf '%s' "$out" | jq -e '.full_name' >/dev/null 2>&1; then
    echo "created: $(printf '%s' "$out" | jq -r .full_name)"
  else
    echo "note: $1 -> $(printf '%s' "$out" | jq -r '.message // .errors[0].message // "exists or failed"' 2>/dev/null)"
  fi
}

echo "== repos =="
create_repo "$PUB" false
create_repo "$PRIV" true

echo "== secret (BRAIN_TOKEN in $OWNER/$PUB) =="
SECRET_VAL="$GH_PAT" SECRET_NAME="BRAIN_TOKEN" REPO="$OWNER/$PUB" SETUP_TOKEN="$GH_PAT" python3 - <<'PY'
import os, sys, json, base64, urllib.request
try:
    from nacl.public import PublicKey, SealedBox
except Exception:
    print("PYNACL_MISSING"); sys.exit(9)
repo, name, val, tok = os.environ["REPO"], os.environ["SECRET_NAME"], os.environ["SECRET_VAL"], os.environ["SETUP_TOKEN"]
def get(u):
    r = urllib.request.Request(u, headers={"Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json"})
    return json.load(urllib.request.urlopen(r))
def put(u, data):
    r = urllib.request.Request(u, data=json.dumps(data).encode(), method="PUT",
        headers={"Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json", "Content-Type": "application/json"})
    return urllib.request.urlopen(r).status
pk = get(f"https://api.github.com/repos/{repo}/actions/secrets/public-key")
sealed = SealedBox(PublicKey(base64.b64decode(pk["key"]))).encrypt(val.encode())
print("secret set:", put(f"https://api.github.com/repos/{repo}/actions/secrets/{name}",
      {"encrypted_value": base64.b64encode(sealed).decode(), "key_id": pk["key_id"]}))
PY
if [[ $? -eq 9 ]]; then
  echo "pynacl missing -> install it (pip install pynacl) and re-run,"
  echo "or add the secret by hand: Settings -> Secrets and variables -> Actions:"
  echo "   name: BRAIN_TOKEN    value: <your PAT>"
fi

echo "== push runner code =="
sed -i "s|__BRAIN_REPO__|$OWNER/$PRIV|g" "$DIR/.github/workflows/run.yml"
grep -q "$OWNER/$PRIV" "$DIR/.github/workflows/run.yml" || { echo "placeholder replace failed"; exit 1; }

askpass="$(mktemp)"
cat > "$askpass" <<EOF
#!/bin/sh
case "\$1" in *Username*) echo "x-access-token";; *Password*) echo "$GH_PAT";; esac
EOF
chmod +x "$askpass"
export GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0

cd "$DIR"
git init -q -b main
git config user.name "hermes"
git config user.email "hermes@localhost"
git add -A
git commit -q -m "hermes-live: self-migrating Hermes runner" || echo "(nothing to commit)"
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/$OWNER/$PUB.git"
git push -q -u origin main || { echo "push failed"; exit 1; }
rm -f "$askpass"
echo "pushed: https://github.com/$OWNER/$PUB"

if [[ -e "$HERMES_HOME/config.yaml" && "${SKIP_INITIAL_SNAPSHOT:-}" != "1" ]]; then
  echo "== initial brain snapshot -> $OWNER/$PRIV (PRIVATE) =="
  tmp="$(mktemp -d)"
  BRAIN_REPO="$OWNER/$PRIV" BRAIN_TOKEN="$GH_PAT" HERMES_HOME="$HERMES_HOME" \
    bash "$DIR/brain.sh" snapshot "$tmp" || echo "WARN: initial snapshot failed"
  rm -rf "$tmp"
else
  echo "== skipped initial brain snapshot =="
fi

cat <<EOF

== done ==
1. Open https://github.com/$OWNER/$PUB/actions and run "hermes-live" manually once
   (the watchdog also self-starts it within ~20 min).
2. Keep $OWNER/$PRIV PRIVATE. It holds config + .env + history.
3. Rotate the PAT you pasted in chat (it was exposed) and update BRAIN_TOKEN.
4. If GitHub ever flags the repo, restore on any VM with:
     bash brain.sh restore state.tar.gz   (see README.md)

EOF
