#!/usr/bin/env bash
# Сборка и установка dspl (CLI) и DsplBar (иконка в статус-баре).
# Запуск: bash install.sh [--cli|--app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CORE="$ROOT/Sources/Core/DisplayCore.swift $ROOT/Sources/Core/Brightness.swift"
BIN_DIR="$HOME/bin"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/DsplBar.app"

command -v swiftc >/dev/null || {
  echo "нет swiftc — поставь Command Line Tools: xcode-select --install" >&2
  exit 1
}

WHAT="${1:---all}"

build_cli() {
  mkdir -p "$BIN_DIR"
  swiftc -O $CORE "$ROOT/Sources/dspl/main.swift" -o "$BIN_DIR/dspl"
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
}

build_app() {
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  swiftc -O $CORE "$ROOT/Sources/DsplBar/main.swift" -o "$APP/Contents/MacOS/DsplBar"

  # Иконка лежит в репозитории собранной; пересобрать — swift Tools/make-icon.swift
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

  cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

  # Ad-hoc подпись: без неё macOS не даст включить автозапуск через SMAppService.
  codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "подписать не удалось, автозапуск может не работать" >&2
  echo "собрано: $APP"
}

case "$WHAT" in
  --cli) build_cli ;;
  --app) build_app ;;
  *)     build_cli; build_app ;;
esac

echo
"$BIN_DIR/dspl" list
