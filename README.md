# openclaw-linux-setup

Production-ready bootstrap for OpenClaw Gateway + Telegram on Ubuntu (host install, systemd, least privilege).

## What it does
- Installs OpenClaw (official installer)
- Creates a dedicated `openclaw` system user
- Writes config to `/etc/openclaw/openclaw.json`
- Stores secrets in `/etc/openclaw/openclaw.env` (0600)
- Runs `openclaw gateway` as a hardened systemd service
- Enables Telegram via long-polling (no inbound HTTPS/webhooks required)

## Quick start
1) Create a Telegram bot token with @BotFather.
2) Run:

```bash
chmod +x ./openclaw-linux-setup.sh
sudo TELEGRAM_BOT_TOKEN='123456:ABC...' ./openclaw-linux-setup.sh
```

## Logs
- `journalctl -u openclaw-gateway.service -f`
- `/var/log/uranus-maint/openclaw-bootstrap-*.log`

## Security notes
- Gateway binds to loopback by default.
- Use SSH tunneling to access UI remotely:
  `ssh -N -L 18789:127.0.0.1:18789 user@host`

## License
MIT
