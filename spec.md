# Spec: WARP-egress для V2Ray через wgcf + wireproxy

## Проблема

V2Ray сервер выходит в интернет через IP VPS (`freedom` outbound). Сервисы блокирующие IP хостинг-провайдеров недоступны через прокси. Нужно направить исходящий трафик через Cloudflare WARP.

## Архитектура

```
Клиент → V2Ray-сервер (:8080) → SOCKS5 warp-out → wireproxy (:40000) → Cloudflare WARP → Интернет
```

- **wgcf** — регистрирует WARP-аккаунт, генерирует WireGuard-профиль
- **wireproxy** — userspace WireGuard-клиент, поднимает SOCKS5 на `127.0.0.1:40000`
- **V2Ray** — outbound `warp-out` типа `socks` → wireproxy; первый outbound = дефолт для всего трафика

Оба пакета (`wgcf`, `wireproxy`) доступны в nixpkgs.

## Файлы: создать/изменить

| Файл | Действие | Описание |
|---|---|---|
| `.gitignore` | Изменить | Добавить `warp/` (секреты WARP) |
| `v2ray-server-config-warp.json` | Создать | Серверный конфиг с WARP outbound |
| `flake.nix` | Заменить | Добавить warp-setup, warp-proxy, server-warp, server-warp-all packages/apps; wgcf+wireproxy в devShell |
| `README.md` | Обновить | Пошаговая инструкция |

Существующие конфиги и apps остаются без изменений.

## Детали реализации

### 1. `.gitignore`

Добавить:
```
warp/
```

### 2. `v2ray-server-config-warp.json`

- Inbounds: vmess на :8080 (как в текущем `v2ray-server-config.json`)
- Outbounds (порядок важен — первый = дефолт):
  1. `warp-out` — `socks` → `127.0.0.1:40000`
  2. `direct-out` — `freedom`
  3. `block-out` — `blackhole`
- Routing: `geosite:category-ads-all` → `block-out`
- Log level: `warning`

### 3. `flake.nix`

Новые packages:

- **`warp-setup`** — одноразовый скрипт:
  - Создаёт `warp/` директорию
  - `wgcf register --accept-tos` (идемпотентно — пропускает если `wgcf-account.toml` существует)
  - `wgcf generate` → `wgcf-profile.conf`
  - Копирует профиль в `wireproxy.conf`, дописывает `[Socks5]\nBindAddress = 127.0.0.1:40000`

- **`warp-proxy`** — запуск wireproxy:
  - Проверяет наличие `warp/wireproxy.conf`
  - `exec wireproxy -c warp/wireproxy.conf`

- **`v2ray-server-warp`** — V2Ray с WARP-конфигом:
  - `exec v2ray run -config v2ray-server-config-warp.json`

- **`v2ray-server-warp-all`** — всё в одном процессе:
  - Запускает wireproxy в фоне
  - Ждёт 2 секунды
  - Запускает V2Ray
  - `trap` для cleanup при выходе

Новые apps: `warp-setup`, `warp-proxy`, `server-warp`, `server-warp-all`

DevShell: добавить `pkgs.wgcf`, `pkgs.wireproxy`

Существующие packages/apps (`v2ray-server`, `v2ray-client`, `v2ray`) — без изменений.

### 4. Структура `warp/` (создаётся `warp-setup`, в `.gitignore`)

```
warp/
├── wgcf-account.toml   # секрет
├── wgcf-profile.conf   # секрет
└── wireproxy.conf       # секрет (профиль + [Socks5] секция)
```

## Доступные команды после реализации

| Команда | Назначение |
|---|---|
| `nix run .#server` | V2Ray сервер, прямой выход (без изменений) |
| `nix run .#client` | V2Ray клиент (без изменений) |
| `nix run .#warp-setup` | Регистрация WARP + генерация конфигов (один раз) |
| `nix run .#warp-proxy` | wireproxy — SOCKS5 на :40000 |
| `nix run .#server-warp` | V2Ray сервер через WARP (нужен запущенный warp-proxy) |
| `nix run .#server-warp-all` | wireproxy + V2Ray в одном процессе |

## Порядок запуска на сервере

```bash
# Одноразово:
nix run .#warp-setup

# Запуск (вариант A — два терминала):
nix run .#warp-proxy        # терминал 1
nix run .#server-warp       # терминал 2

# Запуск (вариант B — один терминал):
nix run .#server-warp-all
```

## Acceptance Criteria

1. `nix run .#warp-setup` создаёт `warp/` с `wgcf-account.toml`, `wgcf-profile.conf`, `wireproxy.conf`
2. `nix run .#warp-proxy` запускает wireproxy, SOCKS5 доступен на `127.0.0.1:40000`
3. `nix run .#server-warp` запускает V2Ray с WARP-egress конфигом
4. `nix run .#server-warp-all` запускает оба процесса, корректно завершает при Ctrl+C
5. Клиентский трафик выходит через Cloudflare WARP IP:
   - `curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.me` → IP Cloudflare (не VPS)
   - `curl --socks5-hostname 127.0.0.1:10808 https://cloudflare.com/cdn-cgi/trace` → `warp=on`
6. `warp/` в `.gitignore` — секреты не попадают в git
7. Существующие apps (`server`, `client`) работают как раньше (обратная совместимость)
8. `nix flake check` проходит без ошибок

## Completion Criteria (когда задача считается выполненной)

Задача завершена когда:
- Все 4 файла созданы/изменены согласно спецификации
- `nix flake check` проходит (или `nix flake show` показывает все packages/apps)
- Конфиги валидны (JSON парсится, Nix evaluates)
- README содержит пошаговую инструкцию

⚠️ Полная end-to-end проверка (WARP IP на выходе) возможна только на реальном сервере с сетевым доступом, не в dev container.
