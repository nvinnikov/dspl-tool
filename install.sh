#!/usr/bin/env bash
# Сборка и установка dspl (CLI) и DsplBar (иконка в статус-баре).
# Запуск: bash install.sh [--cli|--app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CORE="$ROOT/Sources/Core/DisplayCore.swift"
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
  swiftc -O "$CORE" "$ROOT/Sources/dspl/main.swift" -o "$BIN_DIR/dspl"
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
  mkdir -p "$APP/Contents/MacOS"
  swiftc -O "$CORE" "$ROOT/Sources/DsplBar/main.swift" -o "$APP/Contents/MacOS/DsplBar"

  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DsplBar</string>
    <key>CFBundleIdentifier</key><string>com.nvinnikov.dsplbar</string>
    <key>CFBundleName</key><string>DsplBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Только статус-бар: без иконки в доке и без переключателя по Cmd-Tab. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

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
