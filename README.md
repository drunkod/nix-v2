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

### Managed together

```bash
nix run .#server-warp-all
```

The all-in-one command waits for wireproxy to open port `40000`, starts V2Ray, and stops the remaining process when either process exits or the command receives a termination signal.

## Verify WARP egress

After the client is connected through V2Ray:

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
| `nix run .#client` | V2Ray client with SOCKS5 on `127.0.0.1:10808` |
| `nix run .#warp-setup` | Register WARP and generate local state |
| `nix run .#warp-proxy` | Run wireproxy SOCKS5 on `127.0.0.1:40000` |
| `nix run .#server-warp` | Run V2Ray with the WARP outbound config |
| `nix run .#server-warp-all` | Run wireproxy and V2Ray with managed cleanup |

## Development and validation

```bash
nix develop
nix flake check
```

The development shell provides `v2ray`, `wgcf`, `wireproxy`, `curl`, and `jq`. `nix flake check` evaluates the flake and validates the primary JSON configuration files.

## Security

- The default `warp/` directory is ignored by Git and contains account secrets. Never commit it.
- Protect a custom `WARP_DIR` with restrictive filesystem permissions.
- Replace the example VMess UUID in both server and client configurations before exposing the service publicly.
