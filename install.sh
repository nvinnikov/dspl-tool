#!/usr/bin/env bash
# Сборка и установка dspl в ~/bin. Запуск: bash install.sh
set -euo pipefail

BIN_DIR="$HOME/bin"
SRC="$(cd "$(dirname "$0")" && pwd)/dspl.swift"

command -v swiftc >/dev/null || {
  echo "нет swiftc — поставь Command Line Tools: xcode-select --install" >&2
  exit 1
}

mkdir -p "$BIN_DIR"
swiftc -O "$SRC" -o "$BIN_DIR/dspl"
echo "собрано: $BIN_DIR/dspl"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    LINE='export PATH="$HOME/bin:$PATH"'
    if ! grep -qF "$LINE" "$HOME/.zshrc" 2>/dev/null; then
      printf '\n%s\n' "$LINE" >> "$HOME/.zshrc"
      echo "добавил ~/bin в PATH в ~/.zshrc — открой новый терминал или: source ~/.zshrc"
    fi
    ;;
esac

echo
"$BIN_DIR/dspl" list
