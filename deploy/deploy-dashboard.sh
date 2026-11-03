#!/usr/bin/env bash
#
# Push dashboard code from this repo checkout to the running service.
#
#   sudo bash /opt/hh-os/deploy/deploy-dashboard.sh
#
# Syntax-checks before restarting: a broken server.js otherwise leaves systemd
# in a restart loop with the panel down and no obvious way back in.

set -euo pipefail

TARGET=/opt/hhos-dashboard
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/dashboard"

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run this with sudo" >&2; exit 1; }
[[ -d "$SRC" ]] || { echo "no dashboard/ in $REPO_DIR" >&2; exit 1; }

# Live calls (dashboard/server.js keeps the count in live-calls.json): a restart of
# the dashboard ends them (the pages are told and reconnect by themselves), and a
# restart of hhos-ai drops the requests HH AI is working on. Say so before
# anything changes; HHOS_DEPLOY_NOWAIT=1 skips the pause.
LIVE_STATUS=/var/lib/hhos-dashboard/live-calls.json
if [[ -f "$LIVE_STATUS" ]]; then
  LIVE_N=$(node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(Number(s.count)||0))}catch(e){process.stdout.write("0")}' "$LIVE_STATUS" 2>/dev/null || echo 0)
  if [[ "${LIVE_N:-0}" -gt 0 ]]; then
    printf '\n\033[1;33m!!\033[0m %s live call(s) open right now:\n' "$LIVE_N" >&2
    node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));for(const c of s.calls||[])console.error("   "+c.call+"  "+c.actor+"  since "+c.since+"  ("+c.state+")")' "$LIVE_STATUS" 2>/dev/null || true
    echo "   Restarting the dashboard ends them; each page is told and reconnects by itself, with backoff." >&2
    if [[ "${HHOS_DEPLOY_NOWAIT:-0}" != "1" ]]; then
      echo "   Continuing in 10 s -- Ctrl-C to stop (HHOS_DEPLOY_NOWAIT=1 skips this pause)." >&2
      sleep 10
    fi
  fi
fi

# The tree being replaced, kept so a bad deploy is one tar command from undone.
if [[ -d "$TARGET" ]]; then
  BACKUP_DIR=/root/backups
  install -d -m 0700 "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/hhos-dashboard_$(date +%Y%m%d_%H%M%S).tgz"
  say "Backing up the current tree to $BACKUP"
  tar -czf "$BACKUP" -C "$(dirname "$TARGET")" --exclude "$(basename "$TARGET")/node_modules" "$(basename "$TARGET")"
fi

# A fresh box (Hamdiano's installer): the panel's account, data and log directories.
if ! id -u hhosadmin >/dev/null 2>&1; then
  say "Creating the hhosadmin service account"
  useradd --system --no-create-home --home-dir /var/lib/hhos-dashboard --shell /usr/sbin/nologin hhosadmin
fi
install -d -m 0750 -o hhosadmin -g hhosadmin /var/lib/hhos-dashboard /var/log/hhos-dashboard

say "Syncing application code"
mkdir -p "$TARGET"
rsync -a --delete \
  --exclude node_modules --exclude .git --exclude 'deploy' \
  "$SRC/" "$TARGET/"

# What is deployed, for HH AI and anyone checking: the commit and when (read at start).
COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
{ [[ -n "$COMMIT" ]] && echo "commit=$COMMIT"; echo "deployed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; [[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]] && echo "dirty=1"; } > "$TARGET/DEPLOYED" || true

say "Installing dependencies if package.json changed"
if [[ ! -d "$TARGET/node_modules" ]] || \
   [[ "$SRC/package.json" -nt "$TARGET/node_modules" ]]; then
  (cd "$TARGET" && npm install --omit=dev --no-audit --no-fund)
fi

say "Checking syntax before restarting"
for f in "$TARGET"/server.js "$TARGET"/lib/*.js; do
  node --check "$f"
done

say "Installing the privileged helper and unit files"
install -m 0755 "$SRC/deploy/hhos-helper" /usr/local/sbin/hhos-helper
python3 -m py_compile /usr/local/sbin/hhos-helper

# Speech to text is OpenAI's by default (lib/voice.js). The old hhos-whisper
# (tiny.en, port 8081) is not installed or started from here; Telegram voice
# notes run whisper-cli directly. Since 2026-09-30 the panel can transcribe on
# this server instead (Settings > Voice > Transcription): its unit is
# hhos-voice-whisper.service, installed here so edits to it land, but started
# only by the panel when a local model is chosen. Its binary and models come
# from deploy/install-voice-whisper.sh (run once; without it the local options
# show as not installed).
install -m 0644 "$SRC/deploy/hhos-voice-whisper.service" /etc/systemd/system/hhos-voice-whisper.service

# The account the panel's console runs as. Separate from hhosagent so the two
# entitlements can never be confused for one another: this one holds full sudo,
# and an agent must never inherit it.
if ! id -u hhosconsole >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/hhos-console/home \
          --shell /bin/bash hhosconsole
fi
# A real shell, not nologin: the console's Bash tool runs commands through one,
# and nologin made every command trip over a profile it could not read.
usermod --shell /bin/bash hhosconsole
# Reading the journal is most of what "check why this is unhappy" means. These
# groups grant it directly, so ordinary log reading does not need sudo and does
# not fill the sudo log with noise that hides the escalations worth seeing.
usermod -aG adm,systemd-journal hhosconsole
# 0711: the console account must walk through this to reach its own config and
# attachments. Everything below it keeps 0700, so this opens the door without
# opening the cupboards.
install -d -m 0711 -o root -g root /var/lib/hhos-console
install -d -m 0700 -o hhosconsole -g hhosconsole /var/lib/hhos-console/home
install -m 0644 "$SRC/deploy/hhos-agent@.service" /etc/systemd/system/hhos-agent@.service
# The dashboard's own unit was installed by hand once and then never again, so
# edits to it in the repo silently did nothing. Installing it here makes the
# repo the source of truth for it, like every other unit.
install -m 0644 "$SRC/deploy/hhos-dashboard.service" /etc/systemd/system/hhos-dashboard.service
install -m 0644 "$SRC/deploy/hhos-whatsapp@.service" /etc/systemd/system/hhos-whatsapp@.service
# HH AI's supervisor listens on a socket only root and the hhosai group can
# open; the panel reaches it by being in that group. Takes effect at the
# restart below.
getent group hhosai >/dev/null || groupadd --system hhosai
usermod -aG hhosai hhosadmin
install -m 0440 "$SRC/deploy/hhos-sudoers" /etc/sudoers.d/hhos-dashboard
visudo -cf /etc/sudoers.d/hhos-dashboard >/dev/null
systemctl daemon-reload

# The live voice's voiceprint (Settings > Voice > Voiceprint): its local
# embedding service, hhos-voiceprint (Unix socket, own account). Installed or
# updated here, before the restart below, because the dashboard's account joins
# the service's group and that takes effect when the dashboard restarts. A
# failure here does not stop the deploy: the relay fails open without it.
if [[ "${HHOS_VOICEPRINT_SKIP:-0}" != "1" ]]; then
  say "The voiceprint service"
  bash "$REPO_DIR/deploy/install-voiceprint.sh" || echo "!! the voiceprint service did not install; the voice works without it (fail-open)" >&2
fi

# ChatGPT for every agent (chatgpt/README.md): the hh-chatgpt broker and the
# ask_chatgpt MCP server the agents load. Skipped where the Codex CLI is absent;
# never restarted while a task runs through it.
if [[ "${HHOS_CHATGPT_SKIP:-0}" != "1" ]] && command -v codex >/dev/null; then
  say "The ChatGPT broker"
  bash "$REPO_DIR/deploy/install-chatgpt.sh" || echo "!! the ChatGPT broker did not install; agents report ChatGPT as unavailable" >&2
fi

say "Restarting the dashboard"
systemctl restart hhos-dashboard
sleep 2
systemctl is-active --quiet hhos-dashboard && say "Dashboard is up" || {
  echo "Dashboard failed to start:" >&2
  journalctl -u hhos-dashboard -n 30 --no-pager >&2
  exit 1
}
