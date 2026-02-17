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
