#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

STOCKFISH_BINARY="${CHESSLENS_STOCKFISH_BIN:-}"
if [[ -z "$STOCKFISH_BINARY" && -x "$PROJECT_DIR/ThirdParty/Stockfish/stockfish" ]]; then
  STOCKFISH_BINARY="$PROJECT_DIR/ThirdParty/Stockfish/stockfish"
fi
if [[ -z "$STOCKFISH_BINARY" ]]; then
  STOCKFISH_BINARY="$(command -v stockfish || true)"
fi
if [[ -z "$STOCKFISH_BINARY" && -x /opt/homebrew/bin/stockfish ]]; then
  STOCKFISH_BINARY=/opt/homebrew/bin/stockfish
fi
if [[ -z "$STOCKFISH_BINARY" && -x /usr/local/bin/stockfish ]]; then
  STOCKFISH_BINARY=/usr/local/bin/stockfish
fi
if [[ ! -x "$STOCKFISH_BINARY" ]]; then
  echo "Stockfish was not found. Install it with 'brew install stockfish', or set CHESSLENS_STOCKFISH_BIN to its executable path." >&2
  exit 1
fi

env \
  CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache" \
  swift build -c release -debug-info-format none --disable-sandbox

APP_DIR="$PROJECT_DIR/dist/ChessLens.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PROJECT_DIR/.build/release/ChessLens" "$MACOS_DIR/ChessLens"
cp -R "$PROJECT_DIR/.build/release/ChessLens_ChessLens.bundle" "$RESOURCES_DIR/"
cp "$STOCKFISH_BINARY" "$RESOURCES_DIR/stockfish"
cp "$PROJECT_DIR/ThirdParty/Stockfish/Copying.txt" "$RESOURCES_DIR/Stockfish-Copying.txt"
cp "$PROJECT_DIR/ThirdParty/Stockfish/NOTICE.md" "$RESOURCES_DIR/Stockfish-NOTICE.md"
chmod +x "$RESOURCES_DIR/stockfish"

sed "s|__EXECUTABLE__|ChessLens|g" "$PROJECT_DIR/support/Info.plist.template" > "$CONTENTS_DIR/Info.plist"

codesign --force --sign - "$RESOURCES_DIR/stockfish"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Built $APP_DIR"
