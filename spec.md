# Спецификация: V2Ray с WARP-egress через wgcf и wireproxy

## Цель

Направить исходящий трафик V2Ray через Cloudflare WARP без привязки к конкретному пути checkout, сохранить прямой режим работы сервера и клиента и обеспечить стабильный запуск на VPS через systemd.

## Архитектура

```text
Удалённый клиент → V2Ray-сервер (:8080) → SOCKS5 warp-out → wireproxy (:40000) → Cloudflare WARP → Интернет
```

Для локальной проверки на VPS полный stack также запускает V2Ray client:

```text
curl → local V2Ray client (:10808) → V2Ray server (:8080) → wireproxy (:40000) → WARP
```

- **wgcf** регистрирует WARP-аккаунт и создаёт WireGuard-профиль.
- **wireproxy** запускает userspace WireGuard-клиент и SOCKS5 listener на `127.0.0.1:40000`.
- **V2Ray server** использует `warp-out` как первый и поэтому основной outbound.
- **V2Ray local client** слушает `127.0.0.1:10808` и подключается к серверу на `127.0.0.1:8080`.
- Рекламные домены `geosite:category-ads-all` направляются в `block-out`.

## WARP state

По умолчанию команды используют:

```text
$PWD/warp
```

Путь можно переопределить переменной окружения:

```bash
export WARP_DIR=/var/lib/nix-v2ray-warp
```

Фактический путь вычисляется как `${WARP_DIR:-$PWD/warp}`. Одинаковое значение должно использоваться при setup и запуске wireproxy.

Структура директории:

```text
warp/
├── wgcf-account.toml   # секрет
├── wgcf-profile.conf   # секрет
└── wireproxy.conf      # секрет: профиль + секция [Socks5]
```

Директория `warp/` находится в `.gitignore`. Скрипт setup использует `umask 077` и устанавливает права `0600` на созданные файлы.

Для systemd deployment состояние по умолчанию хранится в `/var/lib/nix-v2ray-warp` с правами `0700` на директорию.

## Конфигурация V2Ray

`v2ray-server-config-warp.json` повторяет inbound основного серверного конфига и содержит следующие outbounds в указанном порядке:

1. `warp-out`: SOCKS5 на `127.0.0.1:40000`.
2. `direct-out`: `freedom` для явных правил прямого выхода.
3. `block-out`: `blackhole` для блокировки.

Параметры:

- log level: `warning`;
- routing: `geosite:category-ads-all` → `block-out`;
- `warp-out` остаётся первым outbound и используется по умолчанию.

Локальный VPS client генерируется из `v2ray-client-config.json`. Адрес VMess server и WebSocket Host переопределяются на `127.0.0.1`, остальные настройки, включая UUID, сохраняются.

## Flake interface

### Packages

- `v2ray-server` — сервер с прямым egress.
- `v2ray-client` — клиент, использующий обычный client config.
- `v2ray-client-local` — локальный VPS client с SOCKS5 на `127.0.0.1:10808`.
- `v2ray` — V2Ray package из nixpkgs.
- `warp-setup` — идемпотентная регистрация аккаунта и генерация конфигов.
- `warp-proxy` — запуск wireproxy с конфигом из WARP state directory.
- `v2ray-server-warp` — V2Ray с WARP outbound config.
- `v2ray-server-warp-all` — совместный запуск wireproxy и V2Ray server.
- `v2ray-stack` — supervision wireproxy, V2Ray server и local V2Ray client.
- `vps-install` — установка или обновление полного stack как systemd service.

Повторяющаяся логика запуска V2Ray и объявления apps вынесена в helper-функции. Default package и default app указывают на прямой V2Ray server.

### Apps

| App | Назначение |
|---|---|
| `server` | V2Ray server с прямым egress |
| `client` | обычный V2Ray client |
| `client-local` | local VPS client → `127.0.0.1:8080` |
| `warp-setup` | подготовка WARP state |
| `warp-proxy` | wireproxy SOCKS5 listener |
| `server-warp` | V2Ray через уже запущенный wireproxy |
| `server-warp-all` | supervision wireproxy и server |
| `stack` | supervision всех трёх процессов |
| `vps-install` | установка/обновление systemd unit |

## Process lifecycle

### `server-warp-all`

1. Проверяет наличие `wireproxy.conf`.
2. Проверяет, что порты `40000` и `8080` свободны.
3. Запускает wireproxy.
4. Ожидает listener `127.0.0.1:40000` вместо фиксированной задержки.
5. Запускает V2Ray server.
6. Ожидает listener `8080`.
7. Ожидает завершения любого процесса.
8. Завершает оставшийся процесс и выполняет `wait` при нормальном выходе, ошибке, Ctrl+C или SIGTERM.

### `stack`

1. Проверяет, что порт `10808` свободен.
2. Запускает `server-warp-all` и ожидает server listener `8080`.
3. Запускает local client и ожидает listener `10808`.
4. Ожидает завершения server stack или client.
5. При завершении любого компонента останавливает оставшиеся процессы.

Такое поведение исключает тихое накопление дублирующих процессов после ручных запусков.

## systemd deployment

`vps-install`:

1. требует root и наличие systemd;
2. использует `${WARP_DIR:-/var/lib/nix-v2ray-warp}`;
3. проверяет `wireproxy.conf`;
4. останавливает прежний `nix-v2ray-warp.service`;
5. отказывается продолжать, пока порты `40000`, `8080` или `10808` заняты сторонними процессами;
6. устанавливает `v2ray-stack` в persistent Nix profile `/nix/var/nix/profiles/nix-v2ray-warp`, создающий GC root;
7. создаёт и включает `/etc/systemd/system/nix-v2ray-warp.service`;
8. запускает unit с `Restart=always` и `RestartSec=5`.

Логи направляются в journald. Cron и `nohup` для production запуска не используются.

## Validation

`checks.config-json` запускает `jq empty` для server, client, сгенерированного local client и WARP JSON configs. Поэтому `nix flake check` проверяет evaluation flake и синтаксис этих конфигов.

Dev shell содержит:

- `v2ray`;
- `wgcf`;
- `wireproxy`;
- `curl`;
- `iproute2`;
- `jq`.

## Порядок запуска

```bash
# Опционально: хранить секреты вне checkout
export WARP_DIR=/var/lib/nix-v2ray-warp

# Один раз
nix run .#warp-setup

# Вариант A: отдельные процессы
nix run .#warp-proxy
nix run .#server-warp

# Вариант B: wireproxy + server
nix run .#server-warp-all

# Вариант C: wireproxy + server + local client
nix run .#stack

# Production systemd deployment
nix run .#vps-install
```

## Проверка egress

После запуска полного stack:

```bash
curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.me
curl --socks5-hostname 127.0.0.1:10808 https://cloudflare.com/cdn-cgi/trace
```

Ожидаемый результат: Cloudflare exit IP и `warp=on`.

## Acceptance criteria

1. Нет абсолютной зависимости от `/root/work/nix-v2` или другого checkout path.
2. `warp-setup` сохраняет account/profile при повторном запуске и безопасно пересоздаёт `wireproxy.conf`.
3. Runtime commands используют `${WARP_DIR:-$PWD/warp}`, а systemd deployment использует постоянный state directory.
4. `server-warp-all` проверяет readiness и корректно очищает оба процесса.
5. `stack` запускает и контролирует порты `40000`, `8080` и `10808` без дублирующих процессов.
6. systemd unit автоматически запускается после boot и перезапускает полный stack после crash.
7. WARP config использует `warning` и блокирует `geosite:category-ads-all`, а не YouTube.
8. Apps `server` и `client` сохраняют прежнее поведение.
9. `nix flake check` проходит и JSON configs валидны.
10. Полная end-to-end проверка WARP выполняется на сервере с сетевым доступом.
