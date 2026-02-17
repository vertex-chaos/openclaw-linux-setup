# Install (host + systemd)

Assumes `TELEGRAM_BOT_TOKEN` is already exported in your shell.

```bash
sudo -E ./openclaw-linux-setup.sh
systemctl status openclaw-gateway.service --no-pager
ss -lntup | grep 18789 || true
```
