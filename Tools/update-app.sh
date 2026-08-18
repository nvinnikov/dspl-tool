#!/usr/bin/env bash
# Обновляет копию приложения в ~/Applications после brew upgrade dspl.
#
# Копия, а не симлинк: macOS рисует ссылку на приложение как алиас — со стрелкой
# и светлой подложкой, — и в Launchpad вместо иконки видна белая рамка.
set -euo pipefail

SRC="$(brew --prefix)/opt/dspl/DsplBar.app"
DST="$HOME/Applications/DsplBar.app"

[ -d "$SRC" ] || { echo "не найдено: $SRC — сначала brew install nvinnikov/dspl/dspl" >&2; exit 1; }

pkill -f "DsplBar" 2>/dev/null || true
sleep 1
rm -rf "$DST"
cp -R "$SRC" "$DST"
open "$DST"
echo "обновлено: $DST"
