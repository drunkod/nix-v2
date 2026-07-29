# nix-v2ray-warp

A Nix flake for running a V2Ray server or client, with optional Cloudflare WARP egress through `wgcf` and `wireproxy`.

## Quick start

```bash
# Direct-egress server
nix run .#server

# Client (update the server address in v2ray-client-config.json first)
nix run .#client
```

The client exposes a SOCKS5 proxy on `127.0.0.1:10808`.

## WARP architecture

```text
Client → V2Ray (:8080) → SOCKS5 warp-out → wireproxy (:40000) → Cloudflare WARP → Internet
```

V2Ray sends its default outbound traffic to the local wireproxy SOCKS5 listener. Advertising domains are routed to the `blackhole` outbound.

## WARP state directory

WARP credentials and generated configuration are stored in:

```text
${WARP_DIR:-$PWD/warp}
```

Run the commands from the repository root to use `./warp`, or set `WARP_DIR` to keep state elsewhere:

```bash
export WARP_DIR=/var/lib/nix-v2ray-warp
```

Use the same `WARP_DIR` value for setup and runtime commands.

## Set up WARP

Register the account and generate the WireGuard and wireproxy configuration:

```bash
nix run .#warp-setup
```

The command is idempotent for the account and WireGuard profile. It creates or refreshes:

- `wgcf-account.toml` — WARP account credentials
- `wgcf-profile.conf` — generated WireGuard profile
- `wireproxy.conf` — profile plus a SOCKS5 listener on `127.0.0.1:40000`

The generated files are written with owner-only permissions.

## Run with WARP

### Separate processes

```bash
# Terminal 1
nix run .#warp-proxy

# Terminal 2
nix run .#server-warp
```

### Managed server and WARP proxy

```bash
nix run .#server-warp-all
```

This command waits for wireproxy to open port `40000`, starts the V2Ray server on `8080`, and stops the remaining process when either process exits.

### Complete three-process VPS stack

```bash
WARP_DIR=/var/lib/nix-v2ray-warp nix run .#stack
```

The stack supervises:

- wireproxy on `127.0.0.1:40000`;
- the WARP-enabled V2Ray server on `0.0.0.0:8080`;
- a local V2Ray client on `127.0.0.1:10808` for testing from the VPS.

The local client is generated from `v2ray-client-config.json`, with its server address overridden to `127.0.0.1`. If any process stops, the stack stops all remaining children rather than leaving duplicate background processes.

## Debian VPS startup with systemd

Use systemd instead of cron or `nohup` for boot startup and crash recovery:

```bash
# One-time WARP setup in persistent storage
WARP_DIR=/var/lib/nix-v2ray-warp nix run .#warp-setup

# Install, enable and start the service
WARP_DIR=/var/lib/nix-v2ray-warp nix run .#vps-install
```

The installed `nix-v2ray-warp.service` restarts the complete stack five seconds after a process failure and writes logs to the system journal.

See [Debian VPS deployment with systemd](docs/vps-systemd.md) for migration from existing `nohup` processes, port-conflict cleanup, logs, upgrades, and troubleshooting.

## Verify WARP egress

After the local or remote client is connected through V2Ray:

```bash
curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.me
# Expected: a Cloudflare exit IP, not the VPS IP

curl --socks5-hostname 127.0.0.1:10808 https://cloudflare.com/cdn-cgi/trace
# Expected: warp=on
```

## Commands

| Command | Description |
|---|---|
| `nix run .#server` | V2Ray server with direct egress |
| `nix run .#client` | V2Ray client using `v2ray-client-config.json` |
| `nix run .#client-local` | Local VPS client pointed at `127.0.0.1:8080` |
| `nix run .#warp-setup` | Register WARP and generate local state |
| `nix run .#warp-proxy` | Run wireproxy SOCKS5 on `127.0.0.1:40000` |
| `nix run .#server-warp` | Run V2Ray with the WARP outbound config |
| `nix run .#server-warp-all` | Supervise wireproxy and the V2Ray server |
| `nix run .#stack` | Supervise wireproxy, server, and local client |
| `nix run .#vps-install` | Install/update the complete stack as a systemd service |

## Development and validation

```bash
nix develop
nix flake check
```

The development shell provides `v2ray`, `wgcf`, `wireproxy`, `curl`, `iproute2`, and `jq`. `nix flake check` evaluates the flake and validates the primary and generated JSON configuration files.

## Security

- The default `warp/` directory is ignored by Git and contains account secrets. Never commit it.
- Protect a custom `WARP_DIR` with restrictive filesystem permissions.
- Replace the example VMess UUID in both server and client configurations before exposing the service publicly.
- Port `10808` is bound only to localhost. Port `8080` is public and should be protected by the VPS firewall and the V2Ray credentials.
