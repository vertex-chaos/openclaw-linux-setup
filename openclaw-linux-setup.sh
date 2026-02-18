#!/usr/bin/env bash
# openclaw-linux-setup.sh
# Vertex Chaos: production-grade OpenClaw Gateway + Telegram (long-polling) bootstrap for Linux hosts.
#
# Usage:
#   sudo TELEGRAM_BOT_TOKEN='123456:ABC...' ./openclaw-linux-setup.sh
#
# What it does:
# - Installs OpenClaw via official installer (skips onboarding)
# - Creates dedicated system user: openclaw
# - Writes config in openclaw user's home: /var/lib/openclaw/.openclaw/openclaw.json
# - Writes secrets as root-only files in /etc/openclaw/ (0600)
# - Installs hardened systemd system service: openclaw-gateway.service
# - Enables Telegram channel using tokenFile; dmPolicy pairing by default
#
# Notes:
# - Telegram channel is long-polling by default; webhook is optional.
# - Gateway binds to loopback by default; use SSH tunnel to access Control UI.

set -euo pipefail

# ----------------------------
# Defaults (override via env)
# ----------------------------
OC_USER="${OC_USER:-openclaw}"
OC_HOME="${OC_HOME:-/var/lib/openclaw}"
OC_ETC="${OC_ETC:-/etc/openclaw}"
OC_LOG_DIR="${OC_LOG_DIR:-/var/log/openclaw}"
MAINT_LOG_DIR="${MAINT_LOG_DIR:-/var/log/uranus-maint}"

GW_PORT="${GW_PORT:-18789}"
GW_BIND="${GW_BIND:-loopback}"             # loopback|lan|tailnet|auto|custom
GW_AUTH="${GW_AUTH:-token}"               # token|password
DM_POLICY="${DM_POLICY:-pairing}"         # pairing|allowlist|open|disabled (Telegram DMs)
GROUP_POLICY="${GROUP_POLICY:-allowlist}" # open|allowlist|disabled (Telegram groups)

# Paths for secrets (root-owned)
TG_TOKEN_FILE="${TG_TOKEN_FILE:-${OC_ETC}/telegram.bot_token}"
GW_TOKEN_FILE="${GW_TOKEN_FILE:-${OC_ETC}/gateway.token}"
OPENCLAW_BIN="${OPENCLAW_BIN:-}"

# OpenClaw config path (owned by openclaw user)
OC_CFG_DIR="${OC_HOME}/.openclaw"
OC_CFG_FILE="${OC_CFG_DIR}/openclaw.json"

# Logging
TS="$(date +%Y%m%d-%H%M%S)"
BOOTSTRAP_LOG="${MAINT_LOG_DIR}/openclaw-setup-${TS}.log"

# ----------------------------
# Helpers
# ----------------------------
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo; echo "==> $*"; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ... ./openclaw-linux-setup.sh"
}

setup_logging() {
  mkdir -p "${MAINT_LOG_DIR}"
  touch "${BOOTSTRAP_LOG}"
  chmod 600 "${BOOTSTRAP_LOG}"
  exec > >(tee -a "${BOOTSTRAP_LOG}") 2>&1
  trap 'echo "[ERROR] line ${LINENO} failed. Log: ${BOOTSTRAP_LOG}"' ERR
}

rand_token() {
  # 48 bytes -> decent token length
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl jq python3 openssl
}

ensure_user_and_dirs() {
  say "Ensuring system user and directories"
  if id -u "${OC_USER}" >/dev/null 2>&1; then
    echo "User ${OC_USER} exists."
  else
    useradd --system --create-home --home-dir "${OC_HOME}" --shell /usr/sbin/nologin "${OC_USER}"
    echo "Created user ${OC_USER} with home ${OC_HOME}"
  fi

  mkdir -p "${OC_ETC}" "${OC_LOG_DIR}" "${OC_CFG_DIR}"
  chown -R "${OC_USER}:${OC_USER}" "${OC_HOME}" "${OC_LOG_DIR}"
  chmod 750 "${OC_HOME}" "${OC_LOG_DIR}"
  chmod 755 "${OC_ETC}"
}

install_openclaw() {
  say "Installing OpenClaw (official installer, skip onboarding)"
  if have openclaw; then
    OPENCLAW_BIN="$(command -v openclaw)"
    echo "openclaw already installed: ${OPENCLAW_BIN}"
    openclaw --version || true
    return 0
  fi

  # Official docs: install.sh recommended; --no-onboard skips onboarding.
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard

  # Common PATH issue after npm global installs (especially under sudo)
  if ! have openclaw && have npm; then
    local npm_global_prefix
    npm_global_prefix="$(npm prefix -g)"
    export PATH="${npm_global_prefix}/bin:${PATH}"
  fi

  have openclaw || die "OpenClaw installed but 'openclaw' not found in PATH. Check npm global bin path."
  OPENCLAW_BIN="$(command -v openclaw)"
  openclaw --version || true
}

write_secret_files() {
  say "Writing secret files (root-only)"
  mkdir -p "${OC_ETC}"
  chmod 750 "${OC_ETC}"

  # Telegram bot token (readable by service user only)
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && ! -s "${TG_TOKEN_FILE}" ]]; then
    die "TELEGRAM_BOT_TOKEN not set and ${TG_TOKEN_FILE} missing. Provide TELEGRAM_BOT_TOKEN in sudo env."
  fi

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    umask 077
    printf "%s\n" "${TELEGRAM_BOT_TOKEN}" > "${TG_TOKEN_FILE}"
    chmod 640 "${TG_TOKEN_FILE}"
    chown root:"${OC_USER}" "${TG_TOKEN_FILE}"
    echo "Wrote Telegram token to ${TG_TOKEN_FILE}"
  else
    echo "Using existing Telegram token file: ${TG_TOKEN_FILE}"
  fi

  # Gateway token (readable by service user only)
  if [[ ! -s "${GW_TOKEN_FILE}" ]]; then
    umask 077
    rand_token > "${GW_TOKEN_FILE}"
    chmod 640 "${GW_TOKEN_FILE}"
    chown root:"${OC_USER}" "${GW_TOKEN_FILE}"
    echo "Generated Gateway token at ${GW_TOKEN_FILE}"
  else
    chown root:"${OC_USER}" "${GW_TOKEN_FILE}"
    chmod 640 "${GW_TOKEN_FILE}"
    echo "Using existing Gateway token file: ${GW_TOKEN_FILE}"
  fi

  if [[ -s "${TG_TOKEN_FILE}" ]]; then
    chown root:"${OC_USER}" "${TG_TOKEN_FILE}"
    chmod 640 "${TG_TOKEN_FILE}"
  fi
}

write_openclaw_config() {
  say "Writing OpenClaw config (owned by ${OC_USER})"
  mkdir -p "${OC_CFG_DIR}"
  chown -R "${OC_USER}:${OC_USER}" "${OC_CFG_DIR}"
  chmod 700 "${OC_CFG_DIR}"

  # Backup existing config if present
  if [[ -f "${OC_CFG_FILE}" ]]; then
    cp -a "${OC_CFG_FILE}" "${OC_CFG_FILE}.bak.${TS}"
  fi

  cat > "${OC_CFG_FILE}" <<JSON
{
  "gateway": {
    "port": ${GW_PORT},
    "bind": "${GW_BIND}",
    "auth": "${GW_AUTH}"
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "tokenFile": "${TG_TOKEN_FILE}",
      "dmPolicy": "${DM_POLICY}",
      "groupPolicy": "${GROUP_POLICY}"
    }
  }
}
JSON

  chown "${OC_USER}:${OC_USER}" "${OC_CFG_FILE}"
  chmod 600 "${OC_CFG_FILE}"
  echo "Wrote ${OC_CFG_FILE}"
}

install_systemd_service() {
  say "Installing hardened systemd service (openclaw-gateway.service)"
  local unit="/etc/systemd/system/openclaw-gateway.service"

  # Use --token to avoid putting secrets in config; CLI supports these flags.
  # The --token flag also sets OPENCLAW_GATEWAY_TOKEN for the process.
  # (Docs: gateway options and gateway install lifecycle)
  cat > "${unit}" <<UNIT
[Unit]
Description=OpenClaw Gateway (system) + Telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OC_USER}
Group=${OC_USER}
WorkingDirectory=${OC_HOME}

# Environment (non-secret)
Environment=OPENCLAW_CONFIG_PATH=${OC_CFG_FILE}
Environment=OPENCLAW_HOME=${OC_HOME}

# Secret token loaded from root-owned, group-readable file at start time.
ExecStart=/bin/bash -lc '${OPENCLAW_BIN} gateway --port ${GW_PORT} --bind ${GW_BIND} --auth ${GW_AUTH} --token "\$(cat ${GW_TOKEN_FILE})"'

Restart=always
RestartSec=3
TimeoutStopSec=20

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${OC_HOME} ${OC_LOG_DIR}
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now openclaw-gateway.service
}

verify() {
  say "Verifying service + port + basic CLI checks"
  systemctl status openclaw-gateway.service --no-pager || true

  echo
  echo "Listening on ${GW_BIND}:${GW_PORT} (expect loopback by default):"
  ss -lntup | grep ":${GW_PORT} " || true

  echo
  echo "Gateway status:"
  sudo -u "${OC_USER}" env OPENCLAW_CONFIG_PATH="${OC_CFG_FILE}" OPENCLAW_HOME="${OC_HOME}" openclaw gateway status || true

  echo
  echo "Doctor (non-fatal):"
  sudo -u "${OC_USER}" env OPENCLAW_CONFIG_PATH="${OC_CFG_FILE}" OPENCLAW_HOME="${OC_HOME}" openclaw doctor || true
}

print_next_steps() {
  say "Next steps"
  echo "1) Control UI (on uranus): http://127.0.0.1:${GW_PORT}/"
  echo
  echo "2) From your laptop, SSH tunnel (recommended):"
  echo "   ssh -N -L ${GW_PORT}:127.0.0.1:${GW_PORT} saitama@192.168.88.12"
  echo "   Then open: http://127.0.0.1:${GW_PORT}/"
  echo
  echo "3) Telegram:"
  echo "   - DM your bot."
  echo "   - DM access is '${DM_POLICY}' by default; approve the pairing code on first contact."
  echo
  echo "Logs:"
  echo "  journalctl -u openclaw-gateway.service -f"
  echo "  bootstrap log: ${BOOTSTRAP_LOG}"
  echo
  echo "Uninstall:"
  echo "  systemctl disable --now openclaw-gateway.service"
  echo "  rm -f /etc/systemd/system/openclaw-gateway.service"
  echo "  systemctl daemon-reload"
}

main() {
  require_root
  setup_logging

  say "Bootstrap start on $(hostname) @ $(date -Is)"
  echo "Log: ${BOOTSTRAP_LOG}"

  apt_install
  ensure_user_and_dirs
  install_openclaw
  write_secret_files
  write_openclaw_config
  install_systemd_service
  verify
  print_next_steps

  say "Done"
}

main "$@"
