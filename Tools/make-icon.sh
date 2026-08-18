#!/usr/bin/env bash
# Собирает Resources/AppIcon.icns из Resources/AppIcon.png.
# Исходник — квадратный PNG со скруглением и прозрачными полями, как принято
# у macOS: рамку и отступы рисует сам файл, iconutil ничего не добавляет.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon.png"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

# Имена файлов задаёт iconutil, отступать от них нельзя.
for pair in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- $pair
  sips -z "$1" "$1" "$SRC" --out "$SET/$2.png" >/dev/null
done

iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "собрано: $ROOT/Resources/AppIcon.icns"
