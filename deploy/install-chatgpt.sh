#!/usr/bin/env bash
#
# Install (or update) hh-chatgpt: the ChatGPT broker every agent uses through
# the ask_chatgpt tool (chatgpt/README.md).
#
#   sudo bash deploy/install-chatgpt.sh        (from the HH_OS checkout)
#
# Idempotent; the service is restarted only when its code or unit changed, and
# then only once nothing is running through it (or with --force).
#
# What it does:
#   - /usr/local/lib/hh-chatgpt: broker.py, chatgpt_mcp.py (the stdio MCP
#     server the agents load), readable by every account; /usr/local/bin/hh-chatgpt;
#   - /etc/hh-chatgpt/config.json, only if missing (limits, allowed accounts);
#   - hh-chatgpt.service, enabled and (re)started; then a status call.
#
# It never touches the sign-in (/root/.codex): `hh-chatgpt login` does that.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/chatgpt"
UNIT_SRC="$REPO_DIR/dashboard/deploy/hh-chatgpt.service"
LIB=/usr/local/lib/hh-chatgpt
CONF=/etc/hh-chatgpt/config.json
SOCK=/run/hh-chatgpt/sock
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run this with sudo"
[[ -f "$SRC/broker.py" && -f "$UNIT_SRC" ]] || die "no chatgpt/ or unit in $REPO_DIR"
command -v codex >/dev/null || die "the Codex CLI is not installed (npm install -g @openai/codex)"

say "chatgpt: code in $LIB"
install -d -m 0755 -o root -g root "$LIB" /etc/hh-chatgpt
CHANGED=0
for f in broker.py chatgpt_mcp.py; do
  if ! cmp -s "$SRC/$f" "$LIB/$f"; then install -m 0644 -o root -g root "$SRC/$f" "$LIB/$f"; CHANGED=1; fi
done
install -m 0755 -o root -g root "$SRC/hh-chatgpt" /usr/local/bin/hh-chatgpt
if [[ ! -f "$CONF" ]]; then
  install -m 0644 -o root -g root "$SRC/config.json" "$CONF"
  CHANGED=1
fi
install -d -m 0700 -o root -g root /var/lib/hh-chatgpt /var/lib/hh-chatgpt/tasks

if ! cmp -s "$UNIT_SRC" /etc/systemd/system/hh-chatgpt.service; then
  install -m 0644 "$UNIT_SRC" /etc/systemd/system/hh-chatgpt.service
  systemctl daemon-reload
  CHANGED=1
fi
systemctl enable hh-chatgpt >/dev/null 2>&1 || true

busy() {
  [[ -S $SOCK ]] || return 1
  python3 - "$SOCK" <<'PY'
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(40); s.connect(sys.argv[1])
    s.sendall(b'{"op":"status"}\n'); r = json.loads(s.makefile().readline())
    sys.exit(0 if (r.get("running") or r.get("queued")) else 1)
except Exception:
    sys.exit(1)
PY
}
if ! systemctl is-active --quiet hh-chatgpt; then
  say "chatgpt: starting hh-chatgpt"; systemctl restart hh-chatgpt
elif [[ $CHANGED -eq 1 ]]; then
  if busy && [[ $FORCE -eq 0 ]]; then
    echo "chatgpt: a task is running; NOT restarting (the new code waits; rerun later or use --force)" >&2
  else
    say "chatgpt: restarting hh-chatgpt"; systemctl restart hh-chatgpt
  fi
fi
for _ in $(seq 1 50); do [[ -S "$SOCK" ]] && break; sleep 0.2; done
/usr/local/bin/hh-chatgpt status || true
