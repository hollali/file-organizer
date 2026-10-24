#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
NAME="organize"

if [[ -f "$BIN_DIR/$NAME" ]]; then
	rm -f "$BIN_DIR/$NAME"
	echo "Removed $BIN_DIR/$NAME"
else
	echo "Not found: $BIN_DIR/$NAME"
fi
