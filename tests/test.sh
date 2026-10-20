#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$SCRIPT_DIR/organize.sh
BASH_BIN=${BASH:-bash}
ROOT=$(mktemp -d)
trap 'cd /; rm -rf "$ROOT"' EXIT

export HOME=$ROOT/home
export XDG_CONFIG_HOME=$ROOT/xdg
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

run() {
	"$BASH_BIN" "$SCRIPT" "$@"
}

workdir() {
	cd "$ROOT/$1" || fail "cannot enter $1"
}

expect_file() { [[ -f $1 ]] || fail "expected file: $1"; }
expect_dir() { [[ -d $1 ]] || fail "expected directory: $1"; }
expect_absent() { [[ ! -e $1 ]] || fail "expected absent: $1"; }
expect_contains() { [[ $1 == *"$2"* ]] || fail "expected '$2' in output: $1"; }

printf 'basic categorization\n'
mkdir -p "$ROOT/basic"
workdir basic
touch photo.JPG doc.pdf song.mp3 archive.tar.gz run.sh noext .hidden photo.png
out=$(run . 2>&1) || fail "basic run failed: $out"
expect_file Images/photo.JPG
expect_file Images/photo.png
expect_file Documents/doc.pdf
expect_file Audio/song.mp3
expect_file Archives/archive.tar.gz
expect_file Code/run.sh
expect_file Other/noext
expect_file .hidden
expect_contains "$out" "Summary:"
expect_contains "$out" "Total"

printf 'collision handling\n'
mkdir -p "$ROOT/collide/a" "$ROOT/collide/b"
workdir collide
touch a/photo.png b/photo.png
run -r . >/dev/null 2>&1 || fail "collision run failed"
expect_file Images/photo.png
expect_file "Images/photo (1).png"

printf 'tv mode\n'
mkdir -p "$ROOT/tv"
workdir tv
touch "Show.S01E02.mkv" "Show.1x03.mp4" "random.mkv"
run --tv . >/dev/null 2>&1 || fail "tv run failed"
expect_file "Videos/Show/Season 01/Show.S01E02.mkv"
expect_file "Videos/Show/Season 01/Show.1x03.mp4"
expect_file Videos/random.mkv

printf 'date sorting and undo\n'
mkdir -p "$ROOT/dates"
workdir dates
touch -t 202403151200 old.png
touch -t 202512011200 new.jpg
run --by-date . >/dev/null 2>&1 || fail "by-date run failed"
expect_file Images/2024/03/old.png
expect_file Images/2025/12/new.jpg
run -u . >/dev/null 2>&1 || fail "undo failed"
expect_file old.png
expect_file new.jpg
expect_absent Images

printf 'custom rules\n'
mkdir -p "$ROOT/rules"
workdir rules
printf '# comment\n  *.pdf -> Documents/Invoices\nreceipt* => Receipts\n' >rules.conf
touch a.pdf receipt-1.txt
run --rules rules.conf . >/dev/null 2>&1 || fail "rules run failed"
expect_file Documents/Invoices/a.pdf
expect_file Receipts/receipt-1.txt
expect_file rules.conf
out=$(run --rules rules.conf -r . 2>&1) || fail "second rules run failed: $out"
expect_contains "$out" "Nothing to organize."

printf 'duplicate detection\n'
mkdir -p "$ROOT/dedupe/Documents"
workdir dedupe
printf 'abc\n' >Documents/keep.pdf
printf 'abc\n' >dup.pdf
out=$(run --dedupe . 2>&1) || fail "dedupe run failed: $out"
expect_file dup.pdf
expect_contains "$out" "duplicate (skipped)"
rm dup.pdf
printf 'abc\n' >dup.pdf
run --duplicates move . >/dev/null 2>&1 || fail "duplicate move failed"
expect_file Duplicates/dup.pdf
expect_absent dup.pdf
run -u . >/dev/null 2>&1 || fail "duplicate undo failed"
expect_file dup.pdf
expect_absent Duplicates

printf 'duplicate delete and dry run\n'
printf 'abc\n' >delete-me.pdf
out=$(run --duplicates delete -n . 2>&1) || fail "dedupe dry run failed: $out"
expect_file delete-me.pdf
expect_contains "$out" "would delete"
run --duplicates delete . >/dev/null 2>&1 || fail "duplicate delete failed"
expect_absent delete-me.pdf

printf 'hidden files and directories\n'
mkdir -p "$ROOT/hidden/.git" "$ROOT/hidden/sub/.cache"
workdir hidden
touch .git/config sub/.cache/blob.txt sub/visible.txt
run -r . >/dev/null 2>&1 || fail "hidden run failed"
expect_file .git/config
expect_file sub/.cache/blob.txt
expect_file Documents/visible.txt

printf 'dry run changes nothing\n'
mkdir -p "$ROOT/dry"
workdir dry
touch a.png
out=$(run -n . 2>&1) || fail "dry run failed: $out"
expect_file a.png
expect_absent Images
expect_contains "$out" "would move"
if compgen -G '.organize-log-*.log' >/dev/null; then
	fail "dry run wrote a log file"
fi

printf 'target directory and undo\n'
mkdir -p "$ROOT/target/src" "$ROOT/target/out"
workdir target
touch src/x.pdf
run -t out src >/dev/null 2>&1 || fail "target run failed"
expect_file out/Documents/x.pdf
run -u src >/dev/null 2>&1 || fail "target undo failed"
expect_file src/x.pdf
expect_absent out/Documents

printf 'empty directory\n'
mkdir -p "$ROOT/empty"
workdir empty
out=$(run . 2>&1) || fail "empty run failed: $out"
expect_contains "$out" "Nothing to organize."

printf 'All tests passed.\n'
