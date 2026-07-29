# Спецификация: V2Ray с WARP-egress через wgcf и wireproxy

## Цель

Направить исходящий трафик V2Ray через Cloudflare WARP без привязки к конкретному пути checkout и сохранить прямой режим работы сервера и клиента.

## Архитектура

```text
Клиент → V2Ray-сервер (:8080) → SOCKS5 warp-out → wireproxy (:40000) → Cloudflare WARP → Интернет
```

- **wgcf** регистрирует WARP-аккаунт и создаёт WireGuard-профиль.
- **wireproxy** запускает userspace WireGuard-клиент и SOCKS5 listener на `127.0.0.1:40000`.
- **V2Ray** использует `warp-out` как первый и поэтому основной outbound.
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

## Конфигурация V2Ray

`v2ray-server-config-warp.json` повторяет inbound основного серверного конфига и содержит следующие outbounds в указанном порядке:

1. `warp-out`: SOCKS5 на `127.0.0.1:40000`.
2. `direct-out`: `freedom` для явных правил прямого выхода.
3. `block-out`: `blackhole` для блокировки.

Параметры:

- log level: `warning`;
- routing: `geosite:category-ads-all` → `block-out`;
- `warp-out` остаётся первым outbound и используется по умолчанию.

## Flake interface

### Packages

- `v2ray-server` — сервер с прямым egress.
- `v2ray-client` — клиент с локальным SOCKS5 на `127.0.0.1:10808`.
- `v2ray` — V2Ray package из nixpkgs.
- `warp-setup` — идемпотентная регистрация аккаунта и генерация конфигов.
- `warp-proxy` — запуск wireproxy с конфигом из WARP state directory.
- `v2ray-server-warp` — V2Ray с WARP outbound config.
- `v2ray-server-warp-all` — совместный запуск wireproxy и V2Ray.

Повторяющаяся логика запуска V2Ray и объявления apps вынесена в helper-функции. Default package и default app указывают на прямой V2Ray server.

### Apps

| App | Назначение |
|---|---|
| `server` | V2Ray server с прямым egress |
| `client` | V2Ray client |
| `warp-setup` | подготовка WARP state |
| `warp-proxy` | wireproxy SOCKS5 listener |
| `server-warp` | V2Ray через уже запущенный wireproxy |
| `server-warp-all` | управляемый запуск обоих процессов |

### All-in-one lifecycle

`server-warp-all`:

1. Проверяет наличие `wireproxy.conf`.
2. Запускает wireproxy.
3. Ожидает доступность `127.0.0.1:40000` вместо фиксированной задержки.
4. Запускает V2Ray.
5. Ожидает завершения любого процесса.
6. Завершает оставшийся процесс и выполняет `wait` при нормальном выходе, ошибке, Ctrl+C или SIGTERM.

### Validation

`checks.config-json` запускает `jq empty` для основных server, client и WARP JSON-конфигов. Поэтому `nix flake check` проверяет evaluation flake и синтаксис этих конфигов.

Dev shell содержит:

- `v2ray`;
- `wgcf`;
- `wireproxy`;
- `curl`;
- `jq`.

## Порядок запуска

```bash
# Опционально: хранить секреты вне checkout
export WARP_DIR=/var/lib/nix-v2ray-warp

# Один раз
nix run .#warp-setup

# Вариант A: два процесса
nix run .#warp-proxy
nix run .#server-warp

# Вариант B: один управляющий процесс
nix run .#server-warp-all
```

## Проверка egress

После подключения клиента:

```bash
curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.me
curl --socks5-hostname 127.0.0.1:10808 https://cloudflare.com/cdn-cgi/trace
```

Ожидаемый результат: Cloudflare exit IP и `warp=on`.

## Acceptance criteria

1. Нет абсолютной зависимости от `/root/work/nix-v2` или другого checkout path.
2. `warp-setup` сохраняет account/profile при повторном запуске и безопасно пересоздаёт `wireproxy.conf`.
3. `warp-proxy` и `server-warp-all` используют `${WARP_DIR:-$PWD/warp}`.
4. `server-warp-all` проверяет readiness и корректно очищает оба процесса.
5. WARP config использует `warning` и блокирует `geosite:category-ads-all`, а не YouTube.
6. Apps `server` и `client` сохраняют прежнее поведение.
7. `nix flake check` проходит и JSON-конфиги валидны.
8. Полная end-to-end проверка WARP выполняется на сервере с сетевым доступом.
