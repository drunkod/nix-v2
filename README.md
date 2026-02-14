# nix-v2

V2Ray server/client flake with optional Cloudflare WARP egress.

## Quick start (without WARP)

```bash
# Server
nix run .#server

# Client (edit v2ray-client-config.json with server IP first)
nix run .#client
```

## WARP egress setup

Routes outbound traffic through Cloudflare WARP so the exit IP belongs to Cloudflare, not the VPS provider.

```
Client → V2Ray (:8080) → SOCKS5 → wireproxy (:40000) → Cloudflare WARP → Internet
```

### Step 1: Register WARP account (one time)

```bash
nix run .#warp-setup
```

Creates `warp/` directory with:
- `wgcf-account.toml` — WARP account credentials
- `wgcf-profile.conf` — WireGuard profile
- `wireproxy.conf` — wireproxy config (profile + SOCKS5 listener on :40000)

### Step 2: Start the server

**Option A** — two terminals:

```bash
# Terminal 1: WARP proxy
nix run .#warp-proxy

# Terminal 2: V2Ray server
nix run .#server-warp
```

**Option B** — single process:

```bash
nix run .#server-warp-all
```

### Step 3: Verify WARP is active

From the client machine (after connecting through V2Ray):

```bash
curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.me
# Should show a Cloudflare IP, not the VPS IP

curl --socks5-hostname 127.0.0.1:10808 https://cloudflare.com/cdn-cgi/trace
# Should contain: warp=on
```

## All available commands

| Command | Description |
|---|---|
| `nix run .#server` | V2Ray server, direct egress |
| `nix run .#client` | V2Ray client (SOCKS5 on :10808) |
| `nix run .#warp-setup` | Register WARP + generate configs (one time) |
| `nix run .#warp-proxy` | wireproxy SOCKS5 on :40000 |
| `nix run .#server-warp` | V2Ray server via WARP (needs running warp-proxy) |
| `nix run .#server-warp-all` | wireproxy + V2Ray in one process |

## Dev shell

```bash
nix develop
# Provides: v2ray, wgcf, wireproxy, curl
```

## Security

The `warp/` directory contains WARP account secrets and is in `.gitignore`. Do not commit it.
