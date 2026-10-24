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
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

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
out=$(run --tv . 2>&1) || fail "tv run failed"
expect_file "Videos/Show/Season 01/Show.S01E02.mkv"
expect_file "Videos/Show/Season 01/Show.1x03.mp4"
expect_file random.mkv
expect_absent "Videos/random.mkv"
expect_contains "$out" "left in place (unidentified video)"

printf 'videos are never dumped into Videos\n'
mkdir -p "$ROOT/videos"
workdir videos
printf 'e1' >"Series.S01E01.mkv"
printf 'e2' >"Other Show S02E01.mkv"
printf 'clip' >"home clip.mp4"
printf 'sample' >sample.mkv
out=$(run . 2>&1) || fail "video default run failed: $out"
expect_file "Series/Season 01/Series.S01E01.mkv"
expect_file "Other Show/Season 02/Other Show S02E01.mkv"
expect_file "home clip.mp4"
expect_file sample.mkv
expect_absent Videos
expect_contains "$out" "left in place (unidentified video)"

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

printf 'music mode\n'
mkdir -p "$ROOT/music"
workdir music
touch "Artist - Album - 01 - Track.mp3" "loose.mp3"
run --music . >/dev/null 2>&1 || fail "music run failed"
expect_file "Audio/Artist/Album/Artist - Album - 01 - Track.mp3"
expect_file Audio/loose.mp3

printf 'trash duplicates\n'
mkdir -p "$ROOT/trashdup/Documents"
workdir trashdup
printf 'abc\n' >Documents/keep.pdf
printf 'abc\n' >dup.pdf
run --duplicates trash . >/dev/null 2>&1 || fail "trash duplicates failed"
expect_absent dup.pdf
expect_absent Duplicates
expect_file "$XDG_DATA_HOME/Trash/files/dup.pdf"
expect_file "$XDG_DATA_HOME/Trash/info/dup.pdf.trashinfo"

printf 'include and exclude globs\n'
mkdir -p "$ROOT/globs"
workdir globs
touch a.png b.png keep.txt
run --exclude '*.png' . >/dev/null 2>&1 || fail "exclude run failed"
expect_file a.png
expect_file b.png
expect_file Documents/keep.txt
run --include '*.png' . >/dev/null 2>&1 || fail "include run failed"
expect_file Images/a.png
expect_file Images/b.png

printf 'size filters\n'
mkdir -p "$ROOT/sizes"
workdir sizes
printf 'x' >tiny.txt
head -c 5120 /dev/zero >big.pdf
run --min-size 1k . >/dev/null 2>&1 || fail "min-size run failed"
expect_file tiny.txt
expect_file Documents/big.pdf

printf 'max size filter\n'
mkdir -p "$ROOT/maxsz"
workdir maxsz
printf 'x' >small.pdf
head -c 2097152 /dev/zero >huge.pdf
run --max-size 1m . >/dev/null 2>&1 || fail "max-size run failed"
expect_file Documents/small.pdf
expect_file huge.pdf

printf 'older-than filter\n'
mkdir -p "$ROOT/age"
workdir age
touch -t 202001011200 old.pdf
touch recent.pdf
run --older-than 30 . >/dev/null 2>&1 || fail "older-than run failed"
expect_file Documents/old.pdf
expect_file recent.pdf

printf 'rename normalization\n'
mkdir -p "$ROOT/rename"
workdir rename
touch "My Photo 01.PNG"
run --rename . >/dev/null 2>&1 || fail "rename run failed"
expect_file "Images/my_photo_01.png"

printf 'link mode and undo\n'
mkdir -p "$ROOT/link"
workdir link
touch doc.pdf
run --link . >/dev/null 2>&1 || fail "link run failed"
expect_file Documents/doc.pdf
[[ -L doc.pdf ]] || fail "expected symlink at doc.pdf"
run -u . >/dev/null 2>&1 || fail "link undo failed"
expect_file doc.pdf
[[ ! -L doc.pdf ]] || fail "expected real file after undo"
expect_absent Documents

printf 'custom category definitions\n'
mkdir -p "$ROOT/customcat"
workdir customcat
printf '@category Comics = cbz cbr\n' >rules.conf
touch issue.cbz other.cbr doc.pdf
run --rules rules.conf . >/dev/null 2>&1 || fail "custom category run failed"
expect_file Comics/issue.cbz
expect_file Comics/other.cbr
expect_file Documents/doc.pdf
expect_file rules.conf

printf 'json summary\n'
mkdir -p "$ROOT/json"
workdir json
touch a.png
out=$(run --json . 2>&1) || fail "json run failed: $out"
expect_contains "$out" '"moved":1'
expect_contains "$out" '"Images"'
expect_contains "$out" '"dry_run":false'

printf 'config file defaults\n'
mkdir -p "$XDG_CONFIG_HOME/organize"
printf -- '--exclude *.png\n' >"$XDG_CONFIG_HOME/organize/config.conf"
mkdir -p "$ROOT/cfgtest"
workdir cfgtest
touch a.png b.pdf
run . >/dev/null 2>&1 || fail "config run failed"
expect_file a.png
expect_file Documents/b.pdf
rm -rf "$XDG_CONFIG_HOME/organize"

printf 'smart media mode\n'
mkdir -p "$ROOT/smart/Show/Season 1" "$ROOT/smart/Show/Season 2" "$ROOT/smart/Inception (2010)"
workdir smart
printf 'ep1' >"Show.S01E01.mkv"
printf 'sub1' >"Show.S01E01.en.srt"
printf 'ep1b' >"Show/Season 1/Episode 02.mkv"
printf 'ep2' >"Show/Season 2/Episode 01.mkv"
printf 'bb1' >"Breaking.Bad.S01E02.mkv"
printf 'movie' >"Inception (2010)/Inception.2010.1080p.BluRay.mkv"
printf 'msub' >"Inception (2010)/Inception.2010.1080p.BluRay.en.srt"
printf 'art' >"Inception (2010)/poster.jpg"
printf 'art' >"Show/Season 1/folder.jpg"
printf 'report' >report.pdf
printf 'notes' >notes.txt
printf 'pic' >photo.jpg
printf 'junk' >sample.mkv
out=$(run --smart . 2>&1) || fail "smart run failed: $out"
expect_file "Show/Season 1/Show.S01E01.mkv"
expect_file "Show/Season 1/Show.S01E01.en.srt"
expect_file "Show/Season 1/Episode 02.mkv"
expect_file "Show/Season 2/Episode 01.mkv"
expect_file "Breaking Bad/Season 01/Breaking.Bad.S01E02.mkv"
expect_file "Movies/Inception (2010)/Inception.2010.1080p.BluRay.mkv"
expect_file "Movies/Inception (2010)/Inception.2010.1080p.BluRay.en.srt"
expect_file "Movies/Inception (2010)/poster.jpg"
expect_file "Show/Season 1/folder.jpg"
expect_file "$HOME/Documents/PDF/report.pdf"
expect_file "$HOME/Documents/Text/notes.txt"
expect_file "$HOME/Pictures/$(date +%Y/%m)/photo.jpg"
expect_file sample.mkv
expect_absent "Show/Season 01"
expect_absent "Inception (2010)"
expect_contains "$out" "left in place (unidentified video)"

printf 'smart mode avoids duplicate files\n'
printf 'ep1' >"Show.S01E01.mkv"
out=$(run --smart . 2>&1) || fail "smart duplicate run failed: $out"
expect_contains "$out" "duplicate (skipped)"
expect_file "Show/Season 1/Show.S01E01.mkv"
expect_absent "Show/Season 1/Show.S01E01 (1).mkv"

printf 'smart mode honors explicit rules\n'
mkdir -p "$ROOT/smartrules"
workdir smartrules
printf '*.mkv -> Custom\n' >rules.conf
printf 'x' >Show.S01E01.mkv
run --smart --rules rules.conf . >/dev/null 2>&1 || fail "smart rules run failed"
expect_file Custom/Show.S01E01.mkv
expect_absent Videos

printf 'smart mode reuses existing case-insensitive folders\n'
mkdir -p "$ROOT/smartreuse/SHOW/season 01"
workdir smartreuse
printf 'x' >Show.S01E01.mkv
run --smart . >/dev/null 2>&1 || fail "smart reuse run failed"
expect_file "SHOW/season 01/Show.S01E01.mkv"
expect_absent Videos

printf 'smart mode undo\n'
workdir smart
run -u . >/dev/null 2>&1 || fail "smart undo failed"
expect_file "Show.S01E01.en.srt"
expect_file "Inception (2010)/Inception.2010.1080p.BluRay.mkv"

printf 'smart mode routes nested media by context\n'
mkdir -p "$ROOT/smart/Rome Trip/Photos" "$ROOT/smart/Taxes 2025" "$ROOT/smart/New Folder" "$ROOT/smart/Web Download" "$ROOT/smart/Show/Season 3"
workdir smart
printf 'pic1' >"Rome Trip/Photos/IMG_001.jpg"
printf 'taxdoc' >"Taxes 2025/invoice.pdf"
printf 'anime' >"New Folder/shot.png"
printf 'nested' >"Web Download/screenshot_01.png"
printf 'loose' >readme.md
printf 'ep3' >"Show/Season 3/Episode 01.mkv"
printf 'subs3' >"Show/Season 3/Episode 01.srt"
printf 'art3' >"Show/Season 3/cover.jpg"
printf 'orphan' >stray.srt
printf 'orphan' >"Rome Trip/lonely.srt"
out=$(run --smart . 2>&1) || fail "smart context run failed: $out"
expect_file "$HOME/Pictures/Rome Trip/$(date +%Y/%m)/IMG_001.jpg"
expect_file "$HOME/Documents/Taxes 2025/PDF/invoice.pdf"
expect_file "$HOME/Pictures/$(date +%Y/%m)/shot.png"
expect_absent "$HOME/Pictures/New Folder"
expect_file "$HOME/Pictures/$(date +%Y/%m)/screenshot_01.png"
expect_absent "$HOME/Pictures/Web Download"
expect_file "$HOME/Documents/Text/readme.md"
expect_file "Show/Season 3/Episode 01.mkv"
expect_file "Show/Season 3/Episode 01.srt"
expect_file "Show/Season 3/cover.jpg"
expect_file stray.srt
expect_file "Rome Trip/lonely.srt"
expect_contains "$out" "left in place"
expect_contains "$out" "no matching video for sidecar"
