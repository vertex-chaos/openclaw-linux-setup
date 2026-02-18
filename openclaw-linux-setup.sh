#!/usr/bin/env bash
# openclaw-linux-setup.sh
# Vertex Chaos: friendly installer for OpenClaw + Ollama (LOCAL) on Debian-based distros.
#
# Goals:
# - Works on any Debian-based distro (Ubuntu/Debian/etc.)
# - NON-root install (run as normal user; uses sudo only for apt/system services)
# - Ollama runs locally on this host (default: http://127.0.0.1:11434)
# - OpenClaw Gateway binds to LAN (0.0.0.0) with TOKEN auth ONLY
# - If TELEGRAM_BOT_TOKEN is exported, Telegram is enabled automatically (token file, not inline)
# - User-level systemd service (survives logout via linger)
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/<ORG>/<REPO>/main/openclaw-linux-setup.sh | bash
#
# Or:
#   chmod +x openclaw-linux-setup.sh && ./openclaw-linux-setup.sh
#
# Optional env overrides:
#   GW_PORT=18789
#   GW_BIND=0.0.0.0
#   OLLAMA_HOST=http://127.0.0.1:11434
#   OLLAMA_MODEL=gpt-oss:20b
#   NONINTERACTIVE=1
#
# Security notes (because humans):
# - Binding 0.0.0.0 exposes the Gateway to your LAN. Token auth is mandatory here.
# - You should still firewall the port to your trusted subnets.
#
set -euo pipefail

# ----------------------------
# Defaults (override via env)
# ----------------------------
GW_PORT="${GW_PORT:-18789}"
GW_BIND="${GW_BIND:-0.0.0.0}"                 # user asked: bind to LAN
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-gpt-oss:20b}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# User-scoped state (non-root)
OC_HOME="${OC_HOME:-$HOME}"
OC_STATE_DIR="${OC_STATE_DIR:-$HOME/.openclaw}"
OC_CFG_FILE="${OC_CFG_FILE:-$OC_STATE_DIR/openclaw.json}"
OC_TOKEN_FILE="${OC_TOKEN_FILE:-$OC_STATE_DIR/gateway.token}"
TG_TOKEN_FILE="${TG_TOKEN_FILE:-$OC_STATE_DIR/telegram.bot_token}"

# systemd user unit
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/openclaw-gateway.service"

# Logging
TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${LOG_DIR:-$HOME/.openclaw/logs}"
BOOTSTRAP_LOG="${BOOTSTRAP_LOG:-$LOG_DIR/install-$TS.log}"

# ----------------------------
# Helpers
# ----------------------------
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo; echo "==> $*"; }

require_non_root() {
  [[ "${EUID}" -ne 0 ]] || die "Do NOT run as root. Run as your normal user: ./openclaw-linux-setup.sh"
}

sudo_maybe() {
  # Use sudo only when needed. Cache credentials once.
  if ! have sudo; then
    die "sudo is required for apt/system tasks (install deps, enable services). Install sudo or run as a sudo-capable user."
  fi
  # If NONINTERACTIVE=1, require passwordless sudo (or cached creds), otherwise fail fast.
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    sudo -n true 2>/dev/null || die "NONINTERACTIVE=1 but sudo needs a password. Run once interactively or configure sudoers."
  else
    sudo -v
  fi
}

setup_logging() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  touch "$BOOTSTRAP_LOG"
  chmod 600 "$BOOTSTRAP_LOG"
  exec > >(tee -a "$BOOTSTRAP_LOG") 2>&1
  trap 'echo "[ERROR] line ${LINENO} failed. Log: ${BOOTSTRAP_LOG}"' ERR
}

rand_token() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
}

apt_install() {
  sudo_maybe
  say "Installing dependencies (apt)"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends \
    ca-certificates curl jq python3 openssl lsof iproute2 \
    nodejs npm
}

install_openclaw_user() {
  say "Installing OpenClaw (user install)"
  if have openclaw; then
    echo "openclaw already present: $(command -v openclaw)"
    openclaw --version || true
    return 0
  fi

  # Official installer (installs via npm/pnpm). We run it as the USER, not sudo.
  # If it installs to an npm global prefix, we set that prefix to a user-owned path.
  mkdir -p "$HOME/.npm-global"
  npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
  export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard

  if ! have openclaw; then
    # last-ditch: re-add npm global bin
    export PATH="$(npm prefix -g)/bin:$PATH" || true
  fi

  have openclaw || die "OpenClaw installed but 'openclaw' not found in PATH. Check npm prefix/global bin."
  openclaw --version || true
}

ensure_state_dirs() {
  say "Preparing user state directories"
  mkdir -p "$OC_STATE_DIR" "$LOG_DIR" "$UNIT_DIR"
  chmod 700 "$OC_STATE_DIR"
  chmod 700 "$LOG_DIR"
}

ensure_gateway_token() {
  say "Ensuring Gateway token (token auth only)"
  if [[ ! -s "$OC_TOKEN_FILE" ]]; then
    umask 077
    rand_token > "$OC_TOKEN_FILE"
    chmod 600 "$OC_TOKEN_FILE"
    echo "Created token: $OC_TOKEN_FILE"
  else
    chmod 600 "$OC_TOKEN_FILE" || true
    echo "Using existing token: $OC_TOKEN_FILE"
  fi
}

maybe_write_telegram_token() {
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    say "Storing Telegram bot token (from TELEGRAM_BOT_TOKEN env var)"
    umask 077
    printf "%s\n" "$TELEGRAM_BOT_TOKEN" > "$TG_TOKEN_FILE"
    chmod 600 "$TG_TOKEN_FILE"
    echo "Wrote: $TG_TOKEN_FILE"
  else
    echo "TELEGRAM_BOT_TOKEN not set; Telegram will remain disabled."
  fi
}

install_ollama_if_needed() {
  say "Ensuring Ollama is installed and reachable at $OLLAMA_HOST"
  if curl -fsS "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
    echo "Ollama is up."
    return 0
  fi

  sudo_maybe

  if ! have ollama; then
    say "Installing Ollama"
    curl -fsSL --proto '=https' --tlsv1.2 https://ollama.com/install.sh | sudo -E bash
  fi

  # Start/enable service if available
  sudo systemctl enable --now ollama >/dev/null 2>&1 || sudo systemctl enable --now ollama.service >/dev/null 2>&1 || true

  # Give it a moment (not forever)
  for _ in $(seq 1 20); do
    if curl -fsS "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
      echo "Ollama is up."
      return 0
    fi
    sleep 0.5
  done

  die "Ollama is not reachable at $OLLAMA_HOST. Check: sudo systemctl status ollama --no-pager"
}

pull_ollama_model() {
  say "Ensuring Ollama model exists: $OLLAMA_MODEL"
  if have ollama; then
    if ollama list | awk '{print $1}' | grep -qx "$OLLAMA_MODEL"; then
      echo "Model already present."
      return 0
    fi
    ollama pull "$OLLAMA_MODEL" || true
    return 0
  fi

  # If ollama binary isn't in PATH (rare), we still verified HTTP.
  echo "ollama CLI not found; skipping model pull (HTTP endpoint is up)."
}

write_openclaw_config() {
  say "Writing OpenClaw config (fixes gateway.auth schema, sets token + optional Telegram, targets local Ollama)"
  # Backup
  if [[ -f "$OC_CFG_FILE" ]]; then
    cp -a "$OC_CFG_FILE" "$OC_CFG_FILE.bak.$TS"
  fi

  # Important: gateway.auth MUST be an OBJECT (not a string) or doctor complains.
  # We keep config minimal and rely on gateway CLI flags for runtime token reading.
  # Also: We set defaults to use Ollama locally. If OpenClaw schema changes, the
  # config-set calls below will correct what it can.
  cat > "$OC_CFG_FILE" <<JSON
{
  "gateway": {
    "mode": "local",
    "port": ${GW_PORT},
    "bind": "${GW_BIND}",
    "auth": { "type": "token" }
  },
  "channels": {
    "telegram": {
      "enabled": ${TELEGRAM_BOT_TOKEN:+true}${TELEGRAM_BOT_TOKEN:+"":-false},
      "tokenFile": "${TG_TOKEN_FILE}",
      "dmPolicy": "pairing",
      "groupPolicy": "allowlist"
    }
  },
  "providers": {
    "ollama": {
      "baseUrl": "${OLLAMA_HOST}"
    }
  },
  "defaults": {
    "model": "ollama:${OLLAMA_MODEL}"
  }
}
JSON
  chmod 600 "$OC_CFG_FILE"
}

apply_openclaw_config_overrides() {
  say "Applying OpenClaw config overrides via CLI (best-effort, schema-safe)"
  export OPENCLAW_HOME="$OC_HOME"
  export OPENCLAW_CONFIG_PATH="$OC_CFG_FILE"

  # These are best-effort because OpenClaw config keys may evolve.
  # They are safe: if a key doesn't exist, we don't fail the install.
  openclaw config set gateway.mode local >/dev/null 2>&1 || true
  openclaw config set gateway.bind "$GW_BIND" >/dev/null 2>&1 || true
  openclaw config set gateway.port "$GW_PORT" >/dev/null 2>&1 || true

  # Make sure gateway.auth is an object-ish structure (the main bug you hit).
  openclaw config set gateway.auth.type token >/dev/null 2>&1 || true

  # Force Ollama default for the main agent/model (avoids "anthropic" nonsense).
  openclaw config set providers.ollama.baseUrl "$OLLAMA_HOST" >/dev/null 2>&1 || true
  openclaw config set defaults.model "ollama:${OLLAMA_MODEL}" >/dev/null 2>&1 || true
  openclaw config set agents.defaults.model "ollama:${OLLAMA_MODEL}" >/dev/null 2>&1 || true

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    openclaw config set channels.telegram.enabled true >/dev/null 2>&1 || true
    openclaw config set channels.telegram.tokenFile "$TG_TOKEN_FILE" >/dev/null 2>&1 || true
    openclaw config set channels.telegram.dmPolicy pairing >/dev/null 2>&1 || true
    openclaw config set channels.telegram.groupPolicy allowlist >/dev/null 2>&1 || true
  else
    openclaw config set channels.telegram.enabled false >/dev/null 2>&1 || true
  fi
}

install_user_systemd_service() {
  say "Installing user-level systemd service (survives logout via linger)"
  cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=OpenClaw Gateway (user, Ollama local)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

# Minimal, predictable PATH (add user npm prefix too)
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:%h/.npm-global/bin:%h/.local/bin
Environment=OPENCLAW_HOME=%h
Environment=OPENCLAW_CONFIG_PATH=%h/.openclaw/openclaw.json

# Token auth only. Token is loaded from user-owned file (0600).
ExecStart=/bin/bash -lc 'exec openclaw gateway --port ${GW_PORT} --bind ${GW_BIND} --auth token --token "\$(cat %h/.openclaw/gateway.token)"'

Restart=always
RestartSec=2
NoNewPrivileges=true

# Hardening for user services (limited compared to system services, but still helps)
PrivateTmp=true
ProtectSystem=strict

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload
  systemctl --user enable --now openclaw-gateway.service

  # Keep it running after logout
  sudo_maybe
  sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || true
}

verify() {
  say "Verifying: Ollama, gateway port, and no external-provider auth errors"
  echo "Ollama HTTP:"
  curl -fsS "$OLLAMA_HOST/api/tags" | head -c 200; echo

  echo
  echo "OpenClaw doctor (non-fatal):"
  export OPENCLAW_HOME="$OC_HOME"
  export OPENCLAW_CONFIG_PATH="$OC_CFG_FILE"
  openclaw doctor || true

  echo
  echo "systemd user unit:"
  systemctl --user status openclaw-gateway.service --no-pager || true

  echo
  echo "Listening on :${GW_PORT} (should include 0.0.0.0:${GW_PORT} if binding to LAN):"
  ss -lntp | grep -E ":${GW_PORT}\b" || true

  echo
  echo "HTTP check:"
  curl -fsS "http://127.0.0.1:${GW_PORT}/" | head -n 5 || true
}

print_next_steps() {
  say "Next steps"
  echo "Gateway UI (local):  http://127.0.0.1:${GW_PORT}/"
  echo "Gateway UI (LAN):    http://<HOST-LAN-IP>:${GW_PORT}/   (token auth required)"
  echo
  echo "Logs:"
  echo "  journalctl --user -u openclaw-gateway.service -f"
  echo "  install log: $BOOTSTRAP_LOG"
  echo
  echo "Firewall (recommended):"
  echo "  Allow ${GW_PORT} only from your trusted LAN hosts/subnets."
  echo
  echo "Uninstall:"
  echo "  systemctl --user disable --now openclaw-gateway.service"
  echo "  rm -f $UNIT_FILE && systemctl --user daemon-reload"
  echo "  (Optional) rm -rf $OC_STATE_DIR"
}

main() {
  require_non_root
  setup_logging

  say "Bootstrap start on $(hostname) @ $(date -Is)"
  echo "Log: $BOOTSTRAP_LOG"

  apt_install
  ensure_state_dirs
  install_ollama_if_needed
  pull_ollama_model
  install_openclaw_user
  ensure_gateway_token
  maybe_write_telegram_token
  write_openclaw_config
  apply_openclaw_config_overrides
  install_user_systemd_service
  verify
  print_next_steps

  say "Done"
}

main "$@"
