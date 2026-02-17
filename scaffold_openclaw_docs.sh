#!/usr/bin/env bash
# scaffold_openclaw_docs.sh
# Scaffolds/updates docs for the openclaw-linux-setup repo.
# Assumes TELEGRAM_BOT_TOKEN is already exported in your shell; uses sudo -E in examples.

set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/repos/github/orgs/vertex-chaos/openclaw-linux-setup}"

cd "$REPO_DIR"
mkdir -p docs

cat > docs/01-install.md <<'MD'
# Install (host + systemd)

Assumes `TELEGRAM_BOT_TOKEN` is already exported in your shell.

```bash
sudo -E ./openclaw-linux-setup.sh
systemctl status openclaw-gateway.service --no-pager
ss -lntup | grep 18789 || true
```
MD

cat > docs/02-telegram.md <<'MD'
# Telegram pairing test

Assumes `TELEGRAM_BOT_TOKEN` is already exported in your shell.

```bash
journalctl -u openclaw-gateway.service -f
```

DM your bot and approve pairing. Watch logs for events.
MD

cat > docs/03-ui-access.md <<'MD'
# Control UI access (safe)

Gateway binds to loopback by default. Use SSH port forwarding from your laptop:

```bash
ssh -N -L 18789:127.0.0.1:18789 saitama@192.168.88.12
```

Open: http://127.0.0.1:18789/
MD

cat > docs/04-troubleshooting.md <<'MD'
# Troubleshooting

## Config invalid: gateway.auth expected object, received string

```bash
sudo jq '
  .gateway.auth |= ( if type=="string" then { "mode": . } else . end )
' /var/lib/openclaw/.openclaw/openclaw.json | sudo tee /var/lib/openclaw/.openclaw/openclaw.json >/dev/null

sudo chown openclaw:openclaw /var/lib/openclaw/.openclaw/openclaw.json
sudo chmod 600 /var/lib/openclaw/.openclaw/openclaw.json
sudo systemctl restart openclaw-gateway.service
```
MD

cat > README.md <<'MD'
# openclaw-linux-setup

Host bootstrap for OpenClaw Gateway + Telegram (systemd, least privilege, loopback UI by default).

Assumes `TELEGRAM_BOT_TOKEN` is already exported in your shell (use `sudo -E`).

## Docs
- docs/01-install.md
- docs/02-telegram.md
- docs/03-ui-access.md
- docs/04-troubleshooting.md
MD

echo "Docs scaffolded/updated in: $REPO_DIR/docs"
echo "README.md updated."

