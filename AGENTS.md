# AGENTS.md

## Lint

Run ShellCheck on every shell script in the repo:

```bash
shellcheck -x ./*.sh
```

Optional syntax check:

```bash
bash -n ./*.sh
```

## Test

There is no automated integration test suite in this repo.

Use this lightweight consistency check for generated docs:

```bash
REPO_DIR="$PWD" ./scaffold_openclaw_docs.sh
git diff -- README.md docs/
```

The second command should show no unexpected changes if docs are already in sync.

## Run

Bootstrap a host (requires root and a valid Telegram bot token):

```bash
export TELEGRAM_BOT_TOKEN='123456:ABC...'
sudo -E ./openclaw-linux-setup.sh
```

Verify service/port after install:

```bash
systemctl status openclaw-gateway.service --no-pager
ss -lntup | grep 18789 || true
```
