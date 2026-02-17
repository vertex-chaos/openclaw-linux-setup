# AGENTS.md

## Install

Install local lint/test tooling (Ubuntu/Debian):

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends make shellcheck bash diffutils
```

Install OpenClaw on a host (requires root + Telegram token):

```bash
export TELEGRAM_BOT_TOKEN='123456:ABC...'
sudo -E ./openclaw-linux-setup.sh
```

## Run

Check service health and listener:

```bash
systemctl status openclaw-gateway.service --no-pager
ss -lntup | grep 18789 || true
```

Follow live logs:

```bash
journalctl -u openclaw-gateway.service -f
```

## Lint

Repo lint target:

```bash
make lint
```

Equivalent direct command:

```bash
shellcheck -x ./*.sh
```

## Troubleshoot

If config has `gateway.auth expected object, received string`:

```bash
sudo jq '
  .gateway.auth |= ( if type=="string" then { "mode": . } else . end )
' /var/lib/openclaw/.openclaw/openclaw.json | sudo tee /var/lib/openclaw/.openclaw/openclaw.json >/dev/null

sudo chown openclaw:openclaw /var/lib/openclaw/.openclaw/openclaw.json
sudo chmod 600 /var/lib/openclaw/.openclaw/openclaw.json
sudo systemctl restart openclaw-gateway.service
```

Run local checks after changes:

```bash
make test
```
