#!/usr/bin/env bash
# Rough benchmark: create N files and time a dry run.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$SCRIPT_DIR/organize.sh
COUNT=${1:-5000}
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

seq 1 "$COUNT" |
	awk -v dir="$DIR" 'BEGIN {
		split("jpg pdf mp3 zip sh txt", ext, " ")
	}
	{
		printf "%s/file-%06d.%s\n", dir, $1, ext[($1 - 1) % 6]
	}' |
	xargs -r touch

start=$(date +%s%N)
bash "$SCRIPT" -n "$DIR" >/dev/null
end=$(date +%s%N)

ms=$(((end - start) / 1000000))
printf 'bench: %d files in %d ms\n' "$COUNT" "$ms"
