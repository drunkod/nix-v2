# Debian VPS deployment with systemd

Use systemd instead of cron or `nohup` for a long-running proxy stack. systemd starts the services after boot, captures logs, stops all child processes together, and restarts the stack when wireproxy, the V2Ray server, or the local V2Ray client exits.

The supervised stack contains:

| Process | Listener | Purpose |
|---|---:|---|
| wireproxy | `127.0.0.1:40000` | Cloudflare WARP SOCKS5 egress |
| V2Ray server | `0.0.0.0:8080` | Remote VMess/WebSocket entrypoint |
| local V2Ray client | `127.0.0.1:10808` | Local SOCKS5 endpoint for VPS testing |

The local client configuration is generated from `v2ray-client-config.json`, but its server address and WebSocket Host are overridden to `127.0.0.1`. The client and server UUID values must still match.

## Why not cron

Cron is suitable for scheduled jobs, not process supervision. A cron entry can start duplicate V2Ray processes, does not reliably stop child processes, and makes crash logs harder to inspect. The systemd unit installed by this flake uses `Restart=always` with a five-second delay and restarts the complete three-process stack after a failure.

## 1. Update the repository

Run these commands from the repository checkout:

```bash
cd /root/work/nix-v2

git fetch origin
git checkout warp
git pull --ff-only origin warp
```

When testing an unmerged pull-request branch, check out that branch instead.

All examples below assume root access, matching a typical single-user Nix installation on a VPS.

## 2. Enable flakes for the shell

You can keep using explicit flags through a shell function:

```bash
nixf() {
  nix --extra-experimental-features 'nix-command flakes' "$@"
}
```

Commands below use `nixf`. Alternatively, enable `nix-command` and `flakes` permanently in the appropriate Nix configuration for your installation.

## 3. Stop old unmanaged processes

Do this before installing the systemd service. Your ports must not already be owned by old `nohup` processes.

```bash
ss -ltnup | grep -E ':(40000|8080|10808)\b' || true
```

For every listed process, inspect its PID and stop it normally:

```bash
ps -fp PID
kill PID
```

Wait a moment and check again:

```bash
ss -ltnup | grep -E ':(40000|8080|10808)\b' || true
```

Do not continue until all three ports are free. In particular, two V2Ray processes listening on `8080` indicate duplicate manual starts.

## 4. Prepare persistent WARP state

The systemd deployment uses `/var/lib/nix-v2ray-warp` by default. This avoids depending on the current working directory.

### Reuse an existing repository-local WARP account

```bash
install -d -m 700 /var/lib/nix-v2ray-warp
cp -a /root/work/nix-v2/warp/. /var/lib/nix-v2ray-warp/
chmod 600 /var/lib/nix-v2ray-warp/*
```

Confirm the required file exists:

```bash
test -f /var/lib/nix-v2ray-warp/wireproxy.conf
```

### Or register a new WARP account

```bash
WARP_DIR=/var/lib/nix-v2ray-warp nixf run .#warp-setup
```

Keep this directory private because it contains WARP credentials.

## 5. Validate the flake and configuration

```bash
nixf flake check
```

Also ensure the VMess UUID in `v2ray-server-config-warp.json` matches the UUID in `v2ray-client-config.json`.

## 6. Test all three processes in the foreground

```bash
WARP_DIR=/var/lib/nix-v2ray-warp nixf run .#stack
```

Expected final message:

```text
All services are ready: wireproxy=:40000, server=:8080, client=:10808
```

In another SSH session, verify the listeners:

```bash
ss -ltnup | grep -E ':(40000|8080|10808)\b'
```

Test WARP through the local client:

```bash
curl --socks5-hostname 127.0.0.1:10808 https://cloudflare.com/cdn-cgi/trace
```

The response should contain `warp=on`.

Stop the foreground test with `Ctrl+C`. The supervisor should stop all three child processes.

## 7. Install and start the systemd service

```bash
WARP_DIR=/var/lib/nix-v2ray-warp nixf run .#vps-install
```

The installer:

1. verifies that `wireproxy.conf` exists;
2. refuses to start while ports `40000`, `8080`, or `10808` are already occupied;
3. installs the stack into a persistent Nix profile so Nix garbage collection cannot remove its runtime;
4. writes `/etc/systemd/system/nix-v2ray-warp.service`;
5. enables the unit at boot and starts it immediately.

Check status:

```bash
systemctl status nix-v2ray-warp.service --no-pager
```

Follow logs:

```bash
journalctl -u nix-v2ray-warp.service -f
```

Show the last 200 log lines:

```bash
journalctl -u nix-v2ray-warp.service -n 200 --no-pager
```

## 8. Normal administration

Restart the full stack:

```bash
systemctl restart nix-v2ray-warp.service
```

Stop it:

```bash
systemctl stop nix-v2ray-warp.service
```

Start it:

```bash
systemctl start nix-v2ray-warp.service
```

Disable automatic boot startup:

```bash
systemctl disable --now nix-v2ray-warp.service
```

Enable it again:

```bash
systemctl enable --now nix-v2ray-warp.service
```

## 9. Upgrade after repository changes

```bash
cd /root/work/nix-v2
git pull --ff-only origin warp
nixf flake check
WARP_DIR=/var/lib/nix-v2ray-warp nixf run .#vps-install
```

Running `vps-install` again updates the persistent Nix profile, rewrites the unit, and restarts the service.

## Troubleshooting

### `wireproxy.conf not found`

The setup and runtime commands used different state directories. Always use:

```bash
WARP_DIR=/var/lib/nix-v2ray-warp
```

The failed command in a home directory usually searches for `$HOME/warp/wireproxy.conf`, not the repository's `warp/wireproxy.conf`.

### `port ... is already in use`

Find the owner:

```bash
ss -ltnup | grep -E ':(40000|8080|10808)\b'
```

Stop old `nohup`, screen, tmux, or manually started processes. Do not run `nix run .#server`, `nix run .#client`, or `nix run .#warp-proxy` separately while the systemd stack is active.

### Service keeps restarting

Read the service logs first:

```bash
journalctl -u nix-v2ray-warp.service -n 200 --no-pager
```

Then inspect kernel messages for an out-of-memory kill, which is possible on a small VPS without swap:

```bash
journalctl -k --no-pager | grep -Ei 'out of memory|killed process|oom' || true
```

If the kernel killed a process, reduce other memory usage or configure swap according to the VPS provider's recommendations.

### Check whether systemd restarted the stack

```bash
systemctl show nix-v2ray-warp.service \
  -p ActiveState -p SubState -p NRestarts -p ExecMainStatus
```

### WARP listener exists but traffic fails

Test wireproxy directly:

```bash
curl --socks5-hostname 127.0.0.1:40000 https://cloudflare.com/cdn-cgi/trace
```

If this fails, inspect the journal for wireproxy errors and consider regenerating the WARP profile:

```bash
systemctl stop nix-v2ray-warp.service
mv /var/lib/nix-v2ray-warp/wgcf-profile.conf \
   /var/lib/nix-v2ray-warp/wgcf-profile.conf.backup
WARP_DIR=/var/lib/nix-v2ray-warp nixf run .#warp-setup
systemctl start nix-v2ray-warp.service
```
