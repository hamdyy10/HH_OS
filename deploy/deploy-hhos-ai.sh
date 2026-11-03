#!/usr/bin/env bash
#
# Install or update HH AI: the supervisor, its hooks, the pinned Claude Code
# CLI, HH AI's home (charter + hook settings) and the systemd unit.
#
#   sudo bash deploy/deploy-hhos-ai.sh               # install / update and restart
#   sudo bash deploy/deploy-hhos-ai.sh --no-restart  # install, leave it running as is
#
# Restarting ends HH AI's current turn (the conversation is kept and resumed).
# Tests first, always:  node hhos-ai/tools/test-classifier.cjs,
# test-protocol.cjs and (as root) test-supervisor.cjs.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/hhos-ai"
TARGET=/opt/hhos-ai
HOME_DIR=/root/hhos-ai
CONF_DIR=/etc/hhos-ai
RESTART=1
[[ "${1:-}" == "--no-restart" ]] && RESTART=0

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "run this with sudo" >&2; exit 1; }
[[ -f "$SRC/supervisor.js" ]] || { echo "no hhos-ai/ in $REPO_DIR" >&2; exit 1; }

# Live calls (dashboard/server.js keeps the count in live-calls.json): a restart of
# the dashboard ends them (the pages are told and reconnect by themselves), and a
# restart of hhos-ai drops the requests HH AI is working on. Say so before
# anything changes; HHOS_DEPLOY_NOWAIT=1 skips the pause.
LIVE_STATUS=/var/lib/hhos-dashboard/live-calls.json
if [[ -f "$LIVE_STATUS" && $RESTART -eq 1 ]]; then
  LIVE_N=$(node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(Number(s.count)||0))}catch(e){process.stdout.write("0")}' "$LIVE_STATUS" 2>/dev/null || echo 0)
  if [[ "${LIVE_N:-0}" -gt 0 ]]; then
    printf '\n\033[1;33m!!\033[0m %s live call(s) open right now:\n' "$LIVE_N" >&2
    node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));for(const c of s.calls||[])console.error("   "+c.call+"  "+c.actor+"  since "+c.since+"  ("+c.state+")")' "$LIVE_STATUS" 2>/dev/null || true
    echo "   A hhos-ai restart keeps the calls open but drops what HH AI is working on for them; --no-restart avoids that." >&2
    if [[ "${HHOS_DEPLOY_NOWAIT:-0}" != "1" ]]; then
      echo "   Continuing in 10 s -- Ctrl-C to stop (HHOS_DEPLOY_NOWAIT=1 skips this pause)." >&2
      sleep 10
    fi
  fi
fi

say "Checking syntax"
for f in "$SRC"/supervisor.js "$SRC"/lib/*.js "$SRC"/hooks/*.js "$SRC"/bin/hhos-ai-ctl "$SRC"/bin/hhos-ai-mcp "$SRC"/bin/hh-session; do
  node --check "$f"
done

say "The hhosai group (who may open the control socket)"
getent group hhosai >/dev/null || groupadd --system hhosai
# The panel is the one client. Group membership takes effect when the panel
# restarts, which deploy-dashboard.sh does.
id -u hhosadmin >/dev/null 2>&1 && usermod -aG hhosai hhosadmin

say "Installing the supervisor to $TARGET"
install -d -m 0755 "$TARGET" "$TARGET/cli"
rsync -a --delete --exclude cli --exclude home --exclude deploy "$SRC/" "$TARGET/"
# What is deployed, for HH AI and anyone checking: the commit and when (read at start).
COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
{ [[ -n "$COMMIT" ]] && echo "commit=$COMMIT"; echo "deployed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; [[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]] && echo "dirty=1"; } > "$TARGET/DEPLOYED" || true
chmod 0755 "$TARGET/hooks/"*.js "$TARGET/bin/hhos-ai-ctl" "$TARGET/bin/hhos-ai-mcp" "$TARGET/bin/hh-session"
ln -sf "$TARGET/bin/hhos-ai-ctl" /usr/local/bin/hhos-ai-ctl

say "Configuration"
install -d -m 0755 "$CONF_DIR"
if [[ ! -f "$CONF_DIR/config.json" ]]; then
  install -m 0644 "$SRC/deploy/config.json" "$CONF_DIR/config.json"
else
  echo "  keeping the existing $CONF_DIR/config.json"
fi
PIN=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).cli_version)' "$CONF_DIR/config.json")

say "Pinning Claude Code $PIN"
# A copy, not a link to /usr/bin/claude: `claude update` or a desktop-app update
# would otherwise change the CLI under a running HH AI. Peer messaging,
# Remote Control in headless mode and can_use_tool are undocumented enough to
# re-verify on every new version before moving the pin (see the README).
PINNED="$TARGET/cli/claude-$PIN"
if [[ ! -x "$PINNED" ]]; then
  SOURCE="${CLAUDE_PIN_SOURCE:-$(readlink -f /usr/bin/claude)}"
  GOT=$("$SOURCE" --version | awk '{print $1}')
  [[ "$GOT" == "$PIN" ]] || { echo "$SOURCE is $GOT, config pins $PIN. Set CLAUDE_PIN_SOURCE to a $PIN binary." >&2; exit 1; }
  install -m 0755 "$SOURCE" "$PINNED"
fi
ln -sfn "claude-$PIN" "$TARGET/cli/claude"
"$TARGET/cli/claude" --version

say "HH AI's home, $HOME_DIR"
install -d -m 0700 "$HOME_DIR" "$HOME_DIR/.claude"
install -m 0644 "$SRC/home/CLAUDE.md" "$HOME_DIR/CLAUDE.md"
install -m 0644 "$SRC/README.md" "$HOME_DIR/README.md"
install -m 0644 "$SRC/home/.claude/settings.json" "$HOME_DIR/.claude/settings.json"

say "systemd unit"
install -m 0644 "$SRC/deploy/hhos-ai.service" /etc/systemd/system/hhos-ai.service
# Hired sessions (M-6): one template unit, instantiated per hire by the supervisor (hh-session@<slug>).
install -m 0644 "$SRC/deploy/hh-session@.service" /etc/systemd/system/hh-session@.service
systemctl daemon-reload
systemctl enable hhos-ai >/dev/null 2>&1

if [[ $RESTART -eq 1 ]]; then
  say "Restarting hhos-ai"
  systemctl restart hhos-ai
else
  systemctl is-active --quiet hhos-ai || systemctl start hhos-ai
fi
sleep 3
systemctl is-active --quiet hhos-ai && say "hhos-ai is up" || {
  echo "hhos-ai failed to start:" >&2
  journalctl -u hhos-ai -n 40 --no-pager >&2
  exit 1
}
