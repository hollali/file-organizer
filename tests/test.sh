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

printf 'version output\n'
out=$(run --version 2>&1) || fail "--version failed: $out"
expect_contains "$out" "organize.sh 1.3.1"

printf 'doctor output\n'
out=$(run --doctor 2>&1) || fail "--doctor failed: $out"
expect_contains "$out" "organize.sh 1.3.1 - dependency check"
expect_contains "$out" "Summary:"
expect_contains "$out" "[OK]"

printf 'dry run changes nothing\n'
mkdir -p "$ROOT/dry"
workdir dry
touch a.png b.pdf
out=$(run -n . 2>&1) || fail "dry run failed: $out"
expect_contains "$out" "would move:"
expect_contains "$out" "Summary (dry run):"
expect_file a.png
expect_file b.pdf
expect_absent Images
expect_absent Documents

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

printf 'series name variants share one folder\n'
mkdir -p "$ROOT/variants/Breaking Bad" "$ROOT/variants/Cafe"
workdir variants
touch "Breaking.Bad.S01E01.mkv" "breaking_bad.S01E02.mkv" "Breaking-Bad.1x03.mkv" \
	"Café.S01E01.mkv" "Cafe.S01E02.mkv"
out=$(run . 2>&1) || fail "variant run failed: $out"
expect_file "Breaking Bad/Season 01/Breaking.Bad.S01E01.mkv"
expect_file "Breaking Bad/Season 01/breaking_bad.S01E02.mkv"
expect_file "Breaking Bad/Season 01/Breaking-Bad.1x03.mkv"
expect_file "Cafe/Season 01/Café.S01E01.mkv"
expect_file "Cafe/Season 01/Cafe.S01E02.mkv"
expect_absent "breaking_bad"
expect_absent "Café"

printf 'tv mode reuses folders across case variants\n'
mkdir -p "$ROOT/tvcase/Videos/Show"
workdir tvcase
touch "Show.S01E01.mkv" "show.S01E02.mkv" "SHOW.1x03.mkv"
out=$(run --tv . 2>&1) || fail "tv case run failed: $out"
expect_file "Videos/Show/Season 01/Show.S01E01.mkv"
expect_file "Videos/Show/Season 01/show.S01E02.mkv"
expect_file "Videos/Show/Season 01/SHOW.1x03.mkv"
expect_absent Videos/show
expect_absent Videos/SHOW

printf 'existing split series folders merge and undo\n'
mkdir -p "$ROOT/merge/Breaking Bad/Season 01" "$ROOT/merge/Breaking-Bad/Season 01"
workdir merge
printf a >"Breaking Bad/Season 01/ep1.mkv"
printf b >"Breaking-Bad/Season 01/ep2.mkv"
out=$(run -n . 2>&1) || fail "merge dry run failed: $out"
expect_contains "$out" "would move:"
expect_file "Breaking-Bad/Season 01/ep2.mkv"
run . >/dev/null 2>&1 || fail "merge run failed"
expect_absent Breaking-Bad
expect_file "Breaking Bad/Season 01/ep1.mkv"
expect_file "Breaking Bad/Season 01/ep2.mkv"
run -u . >/dev/null 2>&1 || fail "merge undo failed"
expect_file "Breaking-Bad/Season 01/ep2.mkv"
expect_absent "Breaking Bad/Season 01/ep2.mkv"

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
out=$(run -u . 2>&1) || fail "delete undo failed: $out"
expect_file delete-me.pdf
expect_contains "$out" "restored: $ROOT/dedupe/delete-me.pdf"
if compgen -G '.organize-deleted' >/dev/null; then
	fail "delete backup left behind"
fi
printf 'abc\n' >purge-me.pdf
run --duplicates delete . >/dev/null 2>&1 || fail "backup purge setup failed"
expect_dir .organize-deleted
printf 'fresh' >fresh.txt
run . >/dev/null 2>&1 || fail "purge run failed"
expect_absent .organize-deleted

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
out=$(run -u . 2>&1) || fail "trash undo failed: $out"
expect_file dup.pdf
expect_absent "$XDG_DATA_HOME/Trash/files/dup.pdf"
expect_absent "$XDG_DATA_HOME/Trash/info/dup.pdf.trashinfo"

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

printf 'smart mode handles bracketed movie names\n'
mkdir -p "$ROOT/smartbrackets"
workdir smartbrackets
printf 'paren' >"Some Movie (2020) 1080p.mkv"
printf 'bracket' >"The Matrix [1999] BluRay.mkv"
out=$(run --smart --dry-run . 2>&1) || fail "smart dry run with bracketed names failed: $out"
expect_contains "$out" "Movies/Some Movie (2020)/"
expect_contains "$out" "Movies/The Matrix (1999)/"
expect_contains "$out" "Summary (dry run):"
out=$(run --smart . 2>&1) || fail "smart run with bracketed names failed: $out"
expect_file "Movies/Some Movie (2020)/Some Movie (2020) 1080p.mkv"
expect_file "Movies/The Matrix (1999)/The Matrix [1999] BluRay.mkv"
expect_contains "$out" "Movies"

printf 'schedule multiple times per day\n'
mkdir -p "$ROOT/bin" "$ROOT/sched" "$ROOT/sched2"
cat >"$ROOT/bin/crontab" <<'STUB'
#!/usr/bin/env bash
file=${CRONTAB_FILE:?}
case ${1:-} in
-l) if [[ -f $file ]]; then cat "$file"; else exit 1; fi ;;
-) cat >"$file" ;;
*) exit 2 ;;
esac
STUB
chmod +x "$ROOT/bin/crontab"
ln -sf "$SCRIPT" "$ROOT/bin/organize"
export PATH="$ROOT/bin:$PATH"
export CRONTAB_FILE="$ROOT/crontab.txt"
printf 'existing job\n' >"$CRONTAB_FILE"
workdir sched
touch keep.png
out=$(run --schedule '08:00,09:30,18:00@.' 2>&1) || fail "schedule failed: $out"
expect_file keep.png
expect_absent Images
expect_contains "$out" "Scheduled: 08:00, 09:30, 18:00 daily"
expect_contains "$(cat "$CRONTAB_FILE")" "existing job"
marker=$(printf '%s' "$ROOT/sched" | cksum)
marker="#organize-cron:${marker%% *}"
expect_contains "$(cat "$CRONTAB_FILE")" "0 8 * * * $ROOT/bin/organize $ROOT/sched $marker"
expect_contains "$(cat "$CRONTAB_FILE")" "30 9 * * * $ROOT/bin/organize $ROOT/sched $marker"
expect_contains "$(cat "$CRONTAB_FILE")" "0 18 * * * $ROOT/bin/organize $ROOT/sched $marker"
[[ $(grep -F -c "$marker" "$CRONTAB_FILE") -eq 3 ]] || fail "expected 3 cron lines"
out=$(run --schedule '06:00@.' 2>&1) || fail "reschedule failed: $out"
[[ $(grep -F -c "$marker" "$CRONTAB_FILE") -eq 1 ]] || fail "reschedule did not replace jobs"

printf 'scheduling another directory keeps existing jobs\n'
marker2=$(printf '%s' "$ROOT/sched2" | cksum)
marker2="#organize-cron:${marker2%% *}"
workdir sched2
touch keep2.png
out=$(run --schedule '07:00@.' 2>&1) || fail "second schedule failed: $out"
expect_contains "$(cat "$CRONTAB_FILE")" "existing job"
expect_contains "$(cat "$CRONTAB_FILE")" "$marker"
expect_contains "$(cat "$CRONTAB_FILE")" "$marker2"
[[ $(grep -F -c "$marker" "$CRONTAB_FILE") -eq 1 ]] || fail "scheduling wiped another directory"
[[ $(grep -F -c "$marker2" "$CRONTAB_FILE") -eq 1 ]] || fail "second directory was not scheduled"

printf 'unschedule only removes the current directory\n'
workdir sched
out=$(run --unschedule 2>&1) || fail "unschedule failed: $out"
expect_contains "$out" "Removed scheduled job"
if grep -Fq "$marker" "$CRONTAB_FILE"; then
	fail "unschedule left cron lines for $ROOT/sched"
fi
expect_contains "$(cat "$CRONTAB_FILE")" "$marker2"
expect_contains "$(cat "$CRONTAB_FILE")" "existing job"
workdir sched2
out=$(run --unschedule 2>&1) || fail "second unschedule failed: $out"
expect_contains "$(cat "$CRONTAB_FILE")" "existing job"
[[ $(grep -F -c '#organize-cron' "$CRONTAB_FILE") -eq 0 ]] || fail "unschedule left cron lines"

printf 'filenames with tabs and newlines\n'
mkdir -p "$ROOT/weird"
workdir weird
printf x >$'tab\tname.pdf'
printf y >$'new\nline.png'
out=$(run . 2>&1) || fail "weird run failed: $out"
out=$(run -u . 2>&1) || fail "weird undo failed: $out"
expect_file $'tab\tname.pdf'
expect_file $'new\nline.png'
expect_absent Images
expect_absent Documents

printf 'failed run rolls back\n'
mkdir -p "$ROOT/rollback" "$ROOT/rollback-bin"
cat >"$ROOT/rollback-bin/mv" <<'STUB'
#!/usr/bin/env bash
f=${MV_COUNT_FILE:?}
n=0; [[ -f $f ]] && n=$(cat "$f")
n=$((n + 1)); printf '%s' "$n" >"$f"
if ((n == 2)); then printf 'simulated mv failure\n' >&2; exit 1; fi
exec /bin/mv "$@"
STUB
chmod +x "$ROOT/rollback-bin/mv"
workdir rollback
printf a >a.png
printf b >b.pdf
out=$(
	MV_COUNT_FILE="$ROOT/mv-count" PATH="$ROOT/rollback-bin:$PATH" \
		"$BASH_BIN" "$SCRIPT" . 2>&1
) && fail "expected the failing run to fail"
expect_contains "$out" "rolling back"
expect_contains "$out" "rollback complete"
expect_file a.png
expect_file b.pdf
expect_absent Images
expect_absent Documents
if compgen -G '.organize-log-*.log' >/dev/null; then
	fail "rollback left a log file"
fi

printf 'explain output\n'
mkdir -p "$ROOT/explain"
workdir explain
touch a.png "Show.S01E01.mkv"
out=$(run --explain -n . 2>&1) || fail "explain run failed: $out"
expect_contains "$out" "why:"
expect_contains "$out" "extension .png"
expect_contains "$out" "TV episode:"

printf 'alias rules\n'
mkdir -p "$ROOT/aliastest"
workdir aliastest
printf '@alias "The Office UK" -> The Office (US)\n' >rules.conf
touch "The.Office.UK.S01E01.mkv"
run --rules rules.conf . >/dev/null 2>&1 || fail "alias run failed"
expect_file "The Office (US)/Season 01/The.Office.UK.S01E01.mkv"
expect_file rules.conf

printf 'plan file and apply\n'
mkdir -p "$ROOT/plantest"
workdir plantest
touch a.png b.pdf
run -n --plan "$ROOT/plan.bin" . >/dev/null 2>&1 || fail "plan run failed"
expect_file a.png
expect_file b.pdf
[[ -s $ROOT/plan.bin ]] || fail "plan file is empty"
out=$(run --apply-plan "$ROOT/plan.bin" 2>&1) || fail "apply plan failed: $out"
expect_file Images/a.png
expect_file Documents/b.pdf

printf 'systemd timer install and remove\n'
mkdir -p "$ROOT/timertest"
workdir timertest
out=$(run --install-timer '08:30,20:00@.' 2>&1) || fail "timer install failed: $out"
expect_contains "$out" "Installed organize-"
tsum=$(printf '%s' "$ROOT/timertest" | cksum)
unit="organize-${tsum%% *}"
expect_file "$XDG_CONFIG_HOME/systemd/user/$unit.service"
expect_contains "$(cat "$XDG_CONFIG_HOME/systemd/user/$unit.timer")" "OnCalendar=*-*-* 08:30:00"
expect_contains "$(cat "$XDG_CONFIG_HOME/systemd/user/$unit.timer")" "OnCalendar=*-*-* 20:00:00"
out=$(run --uninstall-timer 2>&1) || fail "timer remove failed: $out"
expect_absent "$XDG_CONFIG_HOME/systemd/user/$unit.timer"
expect_absent "$XDG_CONFIG_HOME/systemd/user/$unit.service"

printf 'smart mode warns about XDG destinations\n'
mkdir -p "$ROOT/smartwarn"
workdir smartwarn
printf pic >warnphoto.jpg
out=$(run --smart . 2>&1) || fail "smart warning run failed: $out"
expect_contains "$out" "outside"
expect_contains "$out" "--use-xdg-dirs"

printf 'smart mode with target keeps media inside target\n'
mkdir -p "$ROOT/smarttarget/src" "$ROOT/smarttarget/out"
workdir smarttarget
printf pic >src/targetphoto.jpg
printf doc >src/targetnotes.txt
out=$(run --smart -t out src 2>&1) || fail "smart target run failed: $out"
expect_file "out/Pictures/$(date +%Y/%m)/targetphoto.jpg"
expect_file out/Documents/Text/targetnotes.txt
expect_absent "$HOME/Pictures/$(date +%Y/%m)/targetphoto.jpg"
expect_absent "$HOME/Documents/Text/targetnotes.txt"

printf 'smart mode honors --use-xdg-dirs with target\n'
mkdir -p "$ROOT/smartxdg/src" "$ROOT/smartxdg/out"
workdir smartxdg
printf pic >src/xdgphoto.jpg
out=$(run --smart --use-xdg-dirs -t out src 2>&1) || fail "smart xdg run failed: $out"
expect_file "$HOME/Pictures/$(date +%Y/%m)/xdgphoto.jpg"
expect_absent out/Pictures

printf 'watch mode\n'
if command -v timeout >/dev/null 2>&1; then
	mkdir -p "$ROOT/watchtest"
	workdir watchtest
	touch a.png half.part
	set +e
	timeout 5 "$BASH_BIN" "$SCRIPT" --watch 1 . >/dev/null 2>&1
	wt=$?
	set -e
	[[ $wt -eq 124 ]] || fail "watch mode should keep running (got $wt)"
	expect_file Images/a.png
	expect_file half.part
	expect_absent Images/half.part
fi

printf 'reorganize existing folders\n'
mkdir -p "$ROOT/reorg/Images" "$ROOT/reorg/Documents" "$ROOT/reorg/Old Shows/Season 1"
workdir reorg
printf pic >Images/photo.png
printf doc >Documents/notes.txt
printf ep >"Old Shows/Season 1/e01.mkv"
printf '*.png -> Pictures\n' >rules.conf
out=$(run -n --rules rules.conf -R . 2>&1) || fail "reorganize dry run failed: $out"
expect_contains "$out" "would move:"
expect_file Images/photo.png
out=$(run --rules rules.conf -R . 2>&1) || fail "reorganize run failed: $out"
expect_file Pictures/photo.png
expect_file Documents/notes.txt
expect_file "Old Shows/Season 1/e01.mkv"
expect_absent Images
expect_contains "$out" "already organized: $ROOT/reorg/Documents/notes.txt"
run -u . >/dev/null 2>&1 || fail "reorganize undo failed"
expect_file Images/photo.png
expect_file "Old Shows/Season 1/e01.mkv"

printf 'menu requires a terminal\n'
out=$(run --menu . </dev/null 2>&1) || true
expect_contains "$out" "--menu requires an interactive terminal"
