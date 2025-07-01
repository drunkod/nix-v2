#!/usr/bin/env bash
#
# Этот скрипт загружает последние версии geoip.dat и geosite.dat,
# вычисляет их хеши и автоматически обновляет файл flake.nix.
#

# Немедленно выходить, если какая-либо команда завершилась с ошибкой
set -e

# Определяем URL-адреса для загрузки
GEOSITE_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/geosite.dat"
GEOSITE_SUM_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/geosite.dat.sha256sum"
GEOIP_URL="https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
FLAKE_FILE="flake.nix"

# Убедимся, что мы находимся в правильной директории
if [ ! -f "$FLAKE_FILE" ]; then
    echo "Ошибка: файл $FLAKE_FILE не найден. Запустите скрипт из корневой папки вашего проекта."
    exit 1
fi

echo "--- Обновление Geo-файлов для V2Ray в $FLAKE_FILE ---"

# Создаем временную директорию, которая будет автоматически удалена при выходе
TMP_DIR=$(mktemp -d)
trap "rm -rf '${TMP_DIR}'" EXIT

# 1. Обновляем geosite.dat
echo "[1/2] Загрузка geosite.dat и его контрольной суммы..."
curl -L -o "${TMP_DIR}/geosite.dat" "$GEOSITE_URL"
curl -L -o "${TMP_DIR}/geosite.dat.sha256sum" "$GEOSITE_SUM_URL"

echo "Проверка контрольной суммы..."
(cd "${TMP_DIR}" && sha256sum -c geosite.dat.sha256sum)

NEW_GEOSITE_HASH=$(nix-prefetch-url "file://${TMP_DIR}/geosite.dat" --type sha256)
echo "Новый хеш geosite.dat: ${NEW_GEOSITE_HASH}"

# 2. Обновляем geoip.dat
echo "[2/2] Загрузка geoip.dat..."
curl -L -o "${TMP_DIR}/geoip.dat" "$GEOIP_URL"

NEW_GEOIP_HASH=$(nix-prefetch-url "file://${TMP_DIR}/geoip.dat" --type sha256)
echo "Новый хеш geoip.dat: ${NEW_GEOIP_HASH}"

# 3. Обновляем flake.nix с помощью sed
echo "Обновление файла flake.nix..."
# Используем специальные комментарии-якоря (# GEOSITE_HASH) для надежной замены
sed -i "s|sha256 = \".*\"; # GEOSITE_HASH|sha256 = \"${NEW_GEOSITE_HASH}\"; # GEOSITE_HASH|" "$FLAKE_FILE"
sed -i "s|sha256 = \".*\"; # GEOIP_HASH|sha256 = \"${NEW_GEOIP_HASH}\"; # GEOIP_HASH|" "$FLAKE_FILE"

echo ""
echo "✅ Готово! Файл flake.nix был успешно обновлен."
echo "Запустите 'nix run .#server', чтобы использовать новые файлы."

