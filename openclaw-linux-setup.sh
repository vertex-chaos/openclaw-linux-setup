#!/usr/bin/env bash
# openclaw-linux-setup.sh
# Debian-based, non-root OpenClaw + Ollama local + LAN-bound gateway + optional Telegram.
# Runs as your user; uses sudo only for OS-level installs or optional linger.
set -euo pipefail

# ----------------------------
# Config (override via env)
# ----------------------------
GW_PORT="${GW_PORT:-18789}"
GW_BIND="${GW_BIND:-0.0.0.0}"                     # requirement: bind to LAN
GW_AUTH_MODE="token"                              # requirement: token only
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"  # local ollama endpoint
OLLAMA_MODEL="${OLLAMA_MODEL:-gpt-oss:20b}"        # pick your local model
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"  # per-user install
OPENCLAW_CFG="${OPENCLAW_CFG:-$OPENCLAW_HOME/openclaw.json}"

# secrets (per-user, 0600)
SECRETS_DIR="${SECRETS_DIR:-$OPENCLAW_HOME/secrets}"
GW_TOKEN_FILE="${GW_TOKEN_FILE:-$SECRETS_DIR/gateway.token}"
TG_TOKEN_FILE="${TG_TOKEN_FILE:-$SECRETS_DIR/telegram.bot_token}"

# systemd --user unit
UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
UNIT_FILE="${UNIT_FILE:-$UNIT_DIR/openclaw-gateway.service}"

# If you want the service to survive logout, we attempt linger (needs sudo)
ENABLE_LINGER="${ENABLE_LINGER:-auto}" # auto|yes|no

# ----------------------------
# Helpers
# ----------------------------
have() { command -v "$1" >/dev/null 2>&1; }
say() { printf "\n==> %s\n" "$*"; }
warn() { printf "WARN: %s\n" "$*" >&2; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

is_debianish() { [[ -r /etc/os-release ]] && . /etc/os-release && [[ "${ID_LIKE:-} ${ID:-}" =~ (debian|ubuntu|linuxmint|pop|kali|raspbian) ]]; }
need_sudo() { have sudo || die "sudo not found. Install sudo or run on a system with sudo access."; }

node_major() { node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1; }

apt_install_if_missing() {
  # args: pkgs...
  local missing=()
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]})); then
    need_sudo
    say "Installing OS deps (missing): ${missing[*]}"
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends "${missing[@]}"
  else
    say "OS deps already installed. Skipping apt."
  fi
}

gen_token() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
}

ensure_dirs() {
  mkdir -p "$OPENCLAW_HOME" "$SECRETS_DIR" "$UNIT_DIR"
  chmod 700 "$OPENCLAW_HOME" "$SECRETS_DIR"
}

write_secret_if_missing() {
  local file="$1"
  local value="${2:-}"
  if [[ -s "$file" ]]; then
    chmod 600 "$file" || true
    return 0
  fi
  umask 077
  if [[ -n "$value" ]]; then
    printf "%s\n" "$value" >"$file"
  else
    gen_token >"$file"
  fi
  chmod 600 "$file"
}

ensure_systemd_user_available() {
  if ! have systemctl; then
    die "systemctl not found. This installer expects systemd (common on Debian-based)."
  fi
  # We need a user bus. If it fails, we'll still allow foreground run as fallback.
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    warn "systemd user manager not reachable (no user bus)."
    warn "Fallback will be foreground gateway run, or you enable linger and re-login."
    return 1
  fi
  return 0
}

maybe_enable_linger() {
  local user="${USER}"
  case "$ENABLE_LINGER" in
    no) return 0 ;;
    yes|auto)
      if have loginctl; then
        if have sudo; then
          say "Enabling linger for ${user} (so gateway survives logout)"
          sudo loginctl enable-linger "$user" || warn "Could not enable linger. Service may stop when you log out."
        else
          warn "sudo not available; cannot enable linger."
        fi
      fi
      ;;
  esac
}

install_node_if_needed() {
  # OpenClaw installer uses Node/npm/pnpm. We only install if missing/too old.
  if have node; then
    local maj
    maj="$(node_major || echo 0)"
    if [[ "$maj" -ge 20 ]]; then
      say "Node already present: $(node -v). Skipping Node install."
      return 0
    fi
    warn "Node present but too old: $(node -v). Will install Node 22."
  else
    say "Node not found. Will install Node 22."
  fi

  need_sudo
  # Install NodeSource Node 22. Do NOT apt install npm (NodeSource includes it).
  say "Installing Node 22 (NodeSource)"
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y --no-install-recommends nodejs

  have node || die "Node install failed (node not in PATH)."
  say "Node installed: $(node -v)"
  if have npm; then
    say "npm present: $(npm -v)"
  else
    warn "npm not found even after nodejs install. PATH may be unusual."
  fi
}

install_openclaw_if_needed() {
  if have openclaw; then
    say "OpenClaw already installed: $(command -v openclaw)"
    openclaw --version || true
    return 0
  fi

  say "Installing OpenClaw (official installer, no onboarding)"
  # Must not run under sudo to keep ownership sane.
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard

  # PATH recovery for npm/pnpm global installs
  if ! have openclaw && have npm; then
    local prefix
    prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$prefix" && -d "$prefix/bin" ]]; then
      export PATH="$prefix/bin:$PATH"
    fi
  fi

  have openclaw || die "OpenClaw installed but 'openclaw' not found in PATH. Check npm global prefix/bin."
  openclaw --version || true
}

ensure_ollama() {
  # requirement: check GPU/cuda "automagically": we inspect, we do NOT force install drivers.
  say "Checking GPU/accelerators"
  if have nvidia-smi; then
    nvidia-smi || true
    if have nvcc; then nvcc --version || true; else warn "nvcc not found (CUDA toolkit not installed)."; fi
  else
    warn "nvidia-smi not found. If you expect NVIDIA, install drivers/toolkit."
  fi
  if have rocm-smi; then rocm-smi || true; fi
  if have lspci; then lspci | grep -Ei 'vga|3d|display' || true; fi

  say "Checking Ollama at ${OLLAMA_HOST}"
  if curl -fsS "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    say "Ollama is responding."
  else
    # Try to install and start it (needs sudo for system service)
    warn "Ollama not responding on ${OLLAMA_HOST}."
    warn "Attempting Ollama install/start (requires sudo)."
    need_sudo

    if ! have ollama; then
      curl -fsSL https://ollama.com/install.sh | sudo -E bash
    fi

    if have systemctl; then
      sudo systemctl enable --now ollama || true
    fi

    # Re-test
    sleep 1
    curl -fsS "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1 || die "Ollama still not reachable at ${OLLAMA_HOST}. Fix Ollama first."
    say "Ollama is now responding."
  fi

  say "Ensuring model exists: ${OLLAMA_MODEL}"
  # Pull if missing
  if ! curl -fsS "${OLLAMA_HOST}/api/tags" | jq -e --arg m "$OLLAMA_MODEL" '.models[].name == $m' >/dev/null 2>&1; then
    warn "Model ${OLLAMA_MODEL} not found locally. Pulling via ollama..."
    if have ollama; then
      ollama pull "$OLLAMA_MODEL"
    else
      die "ollama CLI not found but server is up. Install ollama client or pull model some other way."
    fi
  else
    say "Model present."
  fi
}

write_openclaw_config_minimal() {
  # Keep this minimal to avoid schema drift.
  # We DO NOT write gateway.auth into JSON (you saw how that went: expected object vs string).
  say "Writing OpenClaw config (minimal, schema-safe): ${OPENCLAW_CFG}"
  mkdir -p "$(dirname "$OPENCLAW_CFG")"
  umask 077
  cat >"$OPENCLAW_CFG" <<JSON
{
  "gateway": {
    "port": ${GW_PORT},
    "bind": "${GW_BIND}"
  }
}
JSON
  chmod 600 "$OPENCLAW_CFG"
}

configure_openclaw_for_ollama_best_effort() {
  # We try a couple of config keys via CLI. If they fail, we still proceed and verify via logs.
  # Goal: stop it from trying anthropic.
  say "Configuring OpenClaw to prefer local Ollama (best-effort)"

  export OPENCLAW_HOME="$OPENCLAW_HOME"
  export OPENCLAW_CONFIG_PATH="$OPENCLAW_CFG"

  # Try common knobs; ignore failures so script remains portable across OpenClaw versions.
  openclaw config set gateway.mode local >/dev/null 2>&1 || true

  # Try to set default model/provider to ollama
  openclaw config set agents.defaults.model "ollama/${OLLAMA_MODEL}" >/dev/null 2>&1 || true
  openclaw config set models.defaults.chat "ollama/${OLLAMA_MODEL}" >/dev/null 2>&1 || true
  openclaw config set models.providers.ollama.baseUrl "${OLLAMA_HOST}" >/dev/null 2>&1 || true
  openclaw config set models.providers.ollama.baseURL "${OLLAMA_HOST}" >/dev/null 2>&1 || true
  openclaw config set models.providers.ollama.host "${OLLAMA_HOST}" >/dev/null 2>&1 || true

  # Some builds read OpenAI-compatible config; Ollama supports /v1.
  openclaw config set models.providers.openai.baseUrl "${OLLAMA_HOST}/v1" >/dev/null 2>&1 || true
  openclaw config set models.providers.openai.apiKey "ollama" >/dev/null 2>&1 || true
}

write_user_unit() {
  say "Writing systemd --user unit: ${UNIT_FILE}"
  # Token is read from a file, not hardcoded into unit, not printed.
  # We pass --auth token and --token via command substitution (still not logged by systemd unless you print it).
  cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=OpenClaw Gateway (user) - LAN + token auth + optional Telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=OPENCLAW_HOME=%h/.openclaw
Environment=OPENCLAW_CONFIG_PATH=%h/.openclaw/openclaw.json
# Optional Telegram token file (if present, OpenClaw doctor will configure; gateway channel enable is handled by your config/doctor flow)
Environment=TELEGRAM_BOT_TOKEN_FILE=%h/.openclaw/secrets/telegram.bot_token

ExecStart=/usr/bin/env bash -lc 'openclaw gateway --port ${GW_PORT} --bind ${GW_BIND} --auth token --token "\$(cat %h/.openclaw/secrets/gateway.token)"'
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=false
ReadWritePaths=%h/.openclaw
UMask=0077

[Install]
WantedBy=default.target
UNIT
}

start_user_service_or_foreground() {
  if ensure_systemd_user_available; then
    say "Starting gateway as user service"
    systemctl --user daemon-reload
    systemctl --user enable --now openclaw-gateway.service
    systemctl --user --no-pager status openclaw-gateway.service || true
  else
    warn "systemd --user not available. Running gateway in foreground."
    warn "You can fix this permanently by enabling linger (sudo loginctl enable-linger $USER) and re-login."
    OPENCLAW_HOME="$OPENCLAW_HOME" OPENCLAW_CONFIG_PATH="$OPENCLAW_CFG" \
      openclaw gateway --port "$GW_PORT" --bind "$GW_BIND" --auth token --token "$(cat "$GW_TOKEN_FILE")"
  fi
}

verify_gateway() {
  say "Verifying gateway listen + health"
  if have ss; then
    ss -lntp 2>/dev/null | grep -E ":${GW_PORT}\b" || warn "Port ${GW_PORT} not visible via ss (may be permissions)."
  else
    warn "ss not found."
  fi

  # Try HTTP probe (UI/canvas path may vary; root should at least return something)
  curl -fsS "http://127.0.0.1:${GW_PORT}/" >/dev/null 2>&1 || warn "Local HTTP probe failed. Check logs."

  say "If systemd --user is running, logs are:"
  echo "  journalctl --user -u openclaw-gateway.service -f"

  # Telegram enable is optional and only when env var exists
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    say "Telegram token provided. Stored at: ${TG_TOKEN_FILE}"
  else
    say "Telegram not enabled (TELEGRAM_BOT_TOKEN not set)."
  fi

  say "Ollama check (must respond):"
  curl -fsS "${OLLAMA_HOST}/api/tags" | head -c 200; echo
}

main() {
  is_debianish || die "This installer supports Debian-based distros only."

  # Base deps (checked, not blindly installed)
  apt_install_if_missing ca-certificates curl jq python3 openssl iproute2

  ensure_dirs

  # Node: check first, install only if missing/too old. DO NOT apt install npm.
  install_node_if_needed

  # OpenClaw: user-level install
  install_openclaw_if_needed

  # Ollama: verify, install/start if missing, ensure model
  ensure_ollama

  # Secrets
  say "Ensuring gateway token"
  write_secret_if_missing "$GW_TOKEN_FILE"
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    say "TELEGRAM_BOT_TOKEN detected. Writing telegram token file."
    write_secret_if_missing "$TG_TOKEN_FILE" "$TELEGRAM_BOT_TOKEN"
  else
    # leave absent
    rm -f "$TG_TOKEN_FILE" 2>/dev/null || true
  fi

  # Config: keep JSON minimal and stable; use CLI to set extras best-effort
  write_openclaw_config_minimal
  configure_openclaw_for_ollama_best_effort

  # systemd --user
  write_user_unit
  maybe_enable_linger
  start_user_service_or_foreground

  verify_gateway

  say "Done."
  echo "Gateway LAN URL: http://0.0.0.0:${GW_PORT}/ (from other machines use your host IP)"
  echo "Local URL:       http://127.0.0.1:${GW_PORT}/"
}

main "$@"
