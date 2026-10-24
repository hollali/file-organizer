#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="${HOME}/.local/bin"
NAME="organize"

mkdir -p "$BIN_DIR"
cp "$SCRIPT_DIR/organize.sh" "$BIN_DIR/$NAME"
chmod +x "$BIN_DIR/$NAME"

echo "Installed to $BIN_DIR/$NAME"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
	echo "Add $BIN_DIR to your PATH (e.g., export PATH=\"\$HOME/.local/bin:\$PATH\")"
fi
