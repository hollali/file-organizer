#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$SCRIPT_DIR/organize.sh
BASH_BIN=${BASH:-bash}
ROOT=$(mktemp -d)
trap 'cd /; rm -rf "$ROOT"' EXIT

export HOME=$ROOT/home
export XDG_CONFIG_HOME=$ROOT/xdg
export XDG_DATA_HOME=$ROOT/xdg-data
export XDG_PICTURES_DIR=$ROOT/pictures
export XDG_DOCUMENTS_DIR=$ROOT/documents
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_PICTURES_DIR" "$XDG_DOCUMENTS_DIR" "$ROOT/work"

fail() {
	printf 'FUZZ FAIL: %s\n' "$*" >&2
	exit 1
}

parts=(alpha 'b eta' $'tab\there' $'new\nline' 'quote"name' "single'quote" 'café'
	'Ünicode' 'semi;colon' 'dash-name' 'under_score' 'paren(1)' 'star*' 'brack[et]'
	'hash#' 'dollar$' 'amp&' 'a.b' 'x=y' 'plus+sign' 'at@sign' 'comma,name')
exts=(png jpg pdf txt mp3 zip mkv sh '' MKV PDF)

RANDOM=20261120
names=()
for ((i = 0; i < 60; i++)); do
	n=1
	((RANDOM % 3 == 0)) && n=2
	name=${parts[RANDOM % ${#parts[@]}]}
	for ((j = 1; j < n; j++)); do
		name+=" ${parts[RANDOM % ${#parts[@]}]}"
	done
	ext=${exts[RANDOM % ${#exts[@]}]}
	[[ -n $ext ]] && name+=".$ext"
	name=${name# }
	[[ $name == .* || $name == */* ]] && continue
	[[ -e $ROOT/work/$name ]] && continue
	printf 'x' >"$ROOT/work/$name" || fail "cannot create: $(printf %q "$name")"
	names+=("$name")
done

((${#names[@]} > 10)) || fail "not enough generated files"

"$BASH_BIN" "$SCRIPT" "$ROOT/work" >/dev/null 2>&1 || fail "organize run failed"
"$BASH_BIN" "$SCRIPT" --undo "$ROOT/work" >/dev/null 2>&1 || fail "undo run failed"

for name in "${names[@]}"; do
	[[ -f $ROOT/work/$name ]] || fail "missing after undo: $(printf %q "$name")"
done

printf 'fuzz: %d files organized and restored\n' "${#names[@]}"
