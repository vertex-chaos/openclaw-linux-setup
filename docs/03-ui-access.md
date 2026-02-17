# Control UI access (safe)

Gateway binds to loopback by default. Use SSH port forwarding from your laptop:

```bash
ssh -N -L 18789:127.0.0.1:18789 saitama@192.168.88.12
```

Open: http://127.0.0.1:18789/
