#!/usr/bin/env bash
#
# organize.sh - sort files and folders into category folders.
#
# Features: extension categories, TV grouping, date sorting, custom rules,
# duplicate detection, dry-run, undo, and a summary report.
#
# Usage: ./organize.sh [options] [directory]
#
set -euo pipefail

SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")

DRY_RUN=0
RECURSIVE=0
MOVE_FOLDERS=0
INCLUDE_HIDDEN=0
UNDO=0
TV_MODE=0
BY_DATE=0
DEDUPE=0
DUP_MODE=skip
RULES_FILE=""
RULES_PATH=""
TARGET=""
DIR=""

CATEGORIES=(Images Documents Videos Audio Archives "Disk Images" Code Fonts Executables Other Folders)

RULE_PATTERNS=()
RULE_DESTS=()
declare -A SIZE_INDEX=()
declare -A HASH_CACHE=()
declare -A SEEN_HASH=()
declare -A COUNT_BY_CAT=()
declare -A SIZE_BY_CAT=()

SHA_CMD=()
CUR_SIZE=0
CUR_HASH=""
DUP_MATCH=""
LAST_DEST=""
MOVED_COUNT=0
MOVED_BYTES=0
DUP_SKIPPED=0
DUP_MOVED=0
DUP_DELETED=0

usage() {
	cat <<'EOF'
Usage: organize.sh [options] [directory]

Sort files in DIRECTORY (default: .) into category folders.

Options:
  -t, --target DIR   Move files into DIR instead of organizing in place
  -r, --recursive    Include files in subdirectories (moved to DIRECTORY/category)
  -F, --folders      Also move top-level subdirectories into Folders/
  -T, --tv           Group TV episodes as Videos/Show/Season NN/
  -H, --hidden       Include hidden files
  -n, --dry-run      Show what would happen without moving anything
  -u, --undo         Undo the most recent run in the given directory
      --by-date      Group files as Category/YYYY/MM/
      --dedupe       Skip files identical to ones already organized
      --duplicates M Handle duplicates: skip (default), delete, or move
      --rules FILE   Load custom rules (default: ~/.config/organize/rules.conf)
  -h, --help         Show this help
EOF
}

die() {
	printf 'organize: %s\n' "$*" >&2
	exit 1
}

while (($# > 0)); do
	case "$1" in
	-t | --target)
		(($# >= 2)) || die "option $1 requires an argument"
		TARGET=$2
		shift 2
		;;
	-r | --recursive)
		RECURSIVE=1
		shift
		;;
	-F | --folders)
		MOVE_FOLDERS=1
		shift
		;;
	-T | --tv)
		TV_MODE=1
		shift
		;;
	-H | --hidden)
		INCLUDE_HIDDEN=1
		shift
		;;
	-n | --dry-run)
		DRY_RUN=1
		shift
		;;
	-u | --undo)
		UNDO=1
		shift
		;;
	--by-date)
		BY_DATE=1
		shift
		;;
	--dedupe)
		DEDUPE=1
		shift
		;;
	--duplicates)
		(($# >= 2)) || die "option $1 requires an argument"
		case "$2" in
		skip | delete | move)
			DUP_MODE=$2
			;;
		*)
			die "invalid duplicate mode: $2 (use skip, delete, or move)"
			;;
		esac
		DEDUPE=1
		shift 2
		;;
	--rules)
		(($# >= 2)) || die "option $1 requires an argument"
		RULES_FILE=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		die "unknown option: $1 (try --help)"
		;;
	*)
		[[ -z $DIR ]] || die "unexpected argument: $1"
		DIR=$1
		shift
		;;
	esac
done

[[ -z $DIR ]] && DIR=.
[[ -d $DIR ]] || die "not a directory: $DIR"
DIR=$(cd -- "$DIR" && pwd)
TARGET=${TARGET:-$DIR}
[[ -d $TARGET ]] || mkdir -p -- "$TARGET"
TARGET=$(cd -- "$TARGET" && pwd)

LOG=""

log_move() {
	[[ $DRY_RUN -eq 1 ]] && return
	if [[ -z $LOG ]]; then
		LOG=$DIR/.organize-log-$(date +%Y%m%d-%H%M%S)-$$.log
		printf '#target\t%s\n' "$TARGET" >"$LOG"
	fi
	printf '%s\t%s\n' "$1" "$2" >>"$LOG"
}

is_hidden_name() {
	[[ $1 == .* && $1 != . && $1 != .. ]]
}

undo_last() {
	local log latest src dest i
	local log_target=$DIR
	local -a logs=()
	local -a srcs=()
	local -a dests=()

	shopt -s nullglob
	logs=("$DIR"/.organize-log-*.log)
	shopt -u nullglob

	((${#logs[@]} > 0)) || die "no organize log found in $DIR"

	latest=${logs[0]}
	for log in "${logs[@]}"; do
		[[ $log -nt $latest ]] && latest=$log
	done

	while IFS=$'\t' read -r src dest; do
		if [[ $src == '#target' ]]; then
			log_target=$dest
			continue
		fi
		srcs+=("$src")
		dests+=("$dest")
	done <"$latest"

	if ((${#srcs[@]} == 0)); then
		rm -f -- "$latest"
		printf 'Nothing to undo.\n'
		return
	fi

	for ((i = ${#srcs[@]} - 1; i >= 0; i--)); do
		src=${srcs[i]}
		dest=${dests[i]}

		if [[ ! -e $dest ]]; then
			printf 'skip (missing): %s\n' "$dest" >&2
			continue
		fi
		mkdir -p -- "$(dirname -- "$src")"
		if [[ -e $src ]]; then
			printf 'skip (target exists): %s\n' "$src" >&2
			continue
		fi
		mv -- "$dest" "$src"
		remove_empty_parents "$dest" "$log_target"
		printf 'restored: %s\n' "$src"
	done

	rm -f -- "$latest"
	printf 'Undo complete.\n'
}

# Remove now-empty folders left behind by the organizer, stopping at the
# directory that was used as the target.
remove_empty_parents() {
	local dir=$1 stop=$2
	dir=$(dirname -- "$dir")
	while [[ $dir == "$stop"/* ]]; do
		rmdir -- "$dir" 2>/dev/null || break
		dir=$(dirname -- "$dir")
	done
}

category_for() {
	local ext
	ext=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

	case "$ext" in
	jpg | jpeg | png | gif | bmp | tiff | tif | webp | svg | heic | heif | avif | raw | cr2 | nef | dng)
		echo Images
		;;
	pdf | doc | docx | txt | rtf | odt | md | markdown | xls | xlsx | ods | ppt | pptx | odp | csv | epub)
		echo Documents
		;;
	mp4 | mkv | avi | mov | wmv | flv | webm | m4v | mpg | mpeg | 3gp | ogv)
		echo Videos
		;;
	mp3 | wav | flac | aac | ogg | m4a | wma | opus | mid | midi)
		echo Audio
		;;
	zip | tar | gz | bz2 | xz | 7z | rar | tgz | tbz2 | txz | zst)
		echo Archives
		;;
	iso | img | dmg)
		echo "Disk Images"
		;;
	sh | bash | zsh | fish | py | js | jsx | ts | tsx | json | yaml | yml | toml | xml | html | htm | css | scss | sass | less | php | rb | go | rs | java | c | h | cpp | hpp | cs | swift | kt | kts | sql | lua | pl | r | m | mm | gradle)
		echo Code
		;;
	ttf | otf | woff | woff2)
		echo Fonts
		;;
	exe | msi | deb | rpm | appimage | apk | flatpak | snap)
		echo Executables
		;;
	*)
		echo Other
		;;
	esac
}

clean_show_name() {
	local s=$1
	s=${s#"${s%%[!._ -]*}"}
	s=${s%"${s##*[!._ -]}"}
	s=${s//./ }
	s=${s//_/ }
	while [[ $s == *"  "* ]]; do
		s=${s//  / }
	done
	printf '%s' "$s"
}

# Print the relative folder for a TV episode, or fail if the name does not
# contain a recognizable season/episode pattern.
tv_category() {
	local base show season
	local re_sxx re_nxn re_season_ep re_season re_s

	base=$(basename -- "$1")
	re_sxx='^(.+)[._ -]+[sS]([0-9]{1,2})[._ ]*[eE][0-9]{1,3}'
	re_nxn='^(.+)[._ -]+([0-9]{1,2})[xX]([0-9]{1,3})'
	re_season_ep='^(.+)[._ -]+[sS]eason[._ -]*([0-9]{1,2})[._ -]*[eE]pisode[._ -]*[0-9]{1,3}'
	re_season='^(.+)[._ -]+[sS]eason[._ ]*([0-9]{1,2})([._ -]|$)'
	re_s='^(.+)[._ -]+[sS]([0-9]{1,2})([._ -]|$)'

	if [[ $base =~ $re_sxx ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	elif [[ $base =~ $re_nxn ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	elif [[ $base =~ $re_season_ep ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	elif [[ $base =~ $re_season ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	elif [[ $base =~ $re_s ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	else
		return 1
	fi

	show=$(clean_show_name "$show")
	[[ -n $show ]] || return 1

	printf 'Videos/%s/Season %02d\n' "$show" "$((10#$season))"
}

unique_path() {
	local dest=$1 is_dir=${2:-0}
	local dir base name ext i=1
	dir=$(dirname -- "$dest")
	name=$(basename -- "$dest")
	dest=$dir/$name

	if [[ $is_dir -eq 0 && $name != .* && $name == *.* ]]; then
		base=${name%.*}
		ext=.${name##*.}
	else
		base=$name
		ext=""
	fi

	while [[ -e $dest ]]; do
		dest=$dir/$base" ($i)"$ext
		i=$((i + 1))
	done
	printf '%s\n' "$dest"
}

move_one() {
	local src=$1 cat=$2 is_dir=${3:-0}
	local dest_dir=$TARGET/$cat
	local dest size=0
	dest=$(unique_path "$dest_dir/$(basename -- "$src")" "$is_dir")
	LAST_DEST=$dest

	if [[ $is_dir -eq 0 ]]; then
		size=$(file_size "$src" 2>/dev/null || printf 0)
	fi

	if [[ $DRY_RUN -eq 1 ]]; then
		printf 'would move: %s -> %s\n' "$src" "$dest"
		record_move "$cat" "$size"
		return
	fi

	mkdir -p -- "$dest_dir"
	mv -- "$src" "$dest"
	log_move "$src" "$dest"
	printf 'moved: %s -> %s\n' "$src" "$dest"
	record_move "$cat" "$size"
}

trim() {
	local s=$1
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

add_managed_dir() {
	local d=$1 cat
	[[ -z $d || $d == . ]] && return 0
	for cat in "${CATEGORIES[@]}"; do
		[[ $cat == "$d" ]] && return 0
	done
	CATEGORIES+=("$d")
}

load_rules() {
	local file=$1 line pattern dest lineno=0
	[[ -f $file ]] || die "rules file not found: $file"

	while IFS= read -r line || [[ -n $line ]]; do
		lineno=$((lineno + 1))
		line=$(trim "$line")
		[[ -z $line || $line == \#* ]] && continue

		if [[ $line == *'->'* ]]; then
			pattern=${line%%->*}
			dest=${line#*->}
		elif [[ $line == *'=>'* ]]; then
			pattern=${line%%=>*}
			dest=${line#*=>}
		else
			die "rules: $file:$lineno: expected 'PATTERN -> FOLDER'"
		fi

		pattern=$(trim "$pattern")
		dest=$(trim "$dest")
		[[ -n $pattern ]] || die "rules: $file:$lineno: empty pattern"
		[[ -n $dest ]] || die "rules: $file:$lineno: empty folder"
		[[ $dest == /* ]] && die "rules: $file:$lineno: folder must be relative"
		case "/$dest/" in
		*/../*)
			die "rules: $file:$lineno: folder must not contain '..'"
			;;
		esac

		while [[ $dest == */ ]]; do
			dest=${dest%/}
		done
		dest=${dest#./}
		[[ -n $dest && $dest != . ]] || die "rules: $file:$lineno: invalid folder"

		RULE_PATTERNS+=("$pattern")
		RULE_DESTS+=("$dest")
		add_managed_dir "${dest%%/*}"
	done <"$file"
}

rule_for() {
	local base=$1 i
	((${#RULE_PATTERNS[@]} > 0)) || return 1

	shopt -s nocasematch
	for ((i = 0; i < ${#RULE_PATTERNS[@]}; i++)); do
		# shellcheck disable=SC2053 # the right-hand side is intentionally a glob
		if [[ $base == ${RULE_PATTERNS[i]} ]]; then
			printf '%s\n' "${RULE_DESTS[i]}"
			shopt -u nocasematch
			return 0
		fi
	done
	shopt -u nocasematch
	return 1
}

date_path() {
	local src=$1 cat=$2 stamp

	if [[ ${cat%%/*} == Images ]] && command -v exiftool >/dev/null 2>&1; then
		stamp=$(exiftool -s3 -d '%Y-%m' -DateTimeOriginal "$src" 2>/dev/null || true)
		[[ -z $stamp ]] && stamp=$(exiftool -s3 -d '%Y-%m' -CreateDate "$src" 2>/dev/null || true)
		if [[ $stamp =~ ^([0-9]{4})-([0-9]{2})$ ]]; then
			printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
			return 0
		fi
	fi

	stamp=$(stat -c %y "$src" 2>/dev/null || true)
	if [[ $stamp =~ ^([0-9]{4})-([0-9]{2}) ]]; then
		printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		return 0
	fi

	stamp=$(date -r "$src" +%Y-%m 2>/dev/null || true)
	if [[ $stamp =~ ^([0-9]{4})-([0-9]{2})$ ]]; then
		printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		return 0
	fi

	return 1
}

file_size() {
	stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null
}

file_hash() {
	local out
	if ((${#SHA_CMD[@]} == 0)); then
		if command -v sha256sum >/dev/null 2>&1; then
			SHA_CMD=(sha256sum)
		elif command -v shasum >/dev/null 2>&1; then
			SHA_CMD=(shasum -a 256)
		elif command -v sha256 >/dev/null 2>&1; then
			SHA_CMD=(sha256)
		else
			die "dedupe requires sha256sum, shasum, or sha256"
		fi
	fi
	out=$("${SHA_CMD[@]}" "$1")
	printf '%s' "${out%% *}"
}

build_dedupe_index() {
	local d f size
	for d in "${CATEGORIES[@]}"; do
		[[ -d $TARGET/$d ]] || continue
		while IFS= read -r -d '' f; do
			size=$(file_size "$f" 2>/dev/null) || continue
			SIZE_INDEX["$size"]+="$f"$'\n'
		done < <(find "$TARGET/$d" -type f -print0 2>/dev/null)
	done
}

# Set DUP_MATCH to the path of an identical file already organized or seen
# in this run. Must be called directly so the counters persist.
find_duplicate() {
	local src=$1 size h key candidates cand ch
	size=$(file_size "$src") || return 1
	h=$(file_hash "$src")
	CUR_SIZE=$size
	CUR_HASH=$h
	key="$size:$h"

	if [[ -n ${SEEN_HASH[$key]:-} ]]; then
		DUP_MATCH=${SEEN_HASH[$key]}
		return 0
	fi

	candidates=${SIZE_INDEX[$size]:-}
	[[ -n $candidates ]] || return 1

	while IFS= read -r cand; do
		[[ -z $cand || $cand == "$src" ]] && continue
		ch=${HASH_CACHE[$cand]:-}
		if [[ -z $ch ]]; then
			ch=$(file_hash "$cand")
			HASH_CACHE["$cand"]=$ch
		fi
		if [[ $ch == "$h" ]]; then
			DUP_MATCH=$cand
			return 0
		fi
	done <<<"$candidates"

	return 1
}

handle_duplicate() {
	local src=$1 match=$2
	case $DUP_MODE in
	skip)
		DUP_SKIPPED=$((DUP_SKIPPED + 1))
		printf 'duplicate (skipped): %s (matches %s)\n' "$src" "$match"
		;;
	delete)
		DUP_DELETED=$((DUP_DELETED + 1))
		if [[ $DRY_RUN -eq 1 ]]; then
			printf 'would delete duplicate: %s (matches %s)\n' "$src" "$match"
		else
			rm -f -- "$src"
			printf 'deleted duplicate: %s (matches %s)\n' "$src" "$match"
		fi
		;;
	move)
		DUP_MOVED=$((DUP_MOVED + 1))
		move_one "$src" Duplicates
		;;
	esac
}

record_move() {
	local cat=${1%%/*} size=$2
	COUNT_BY_CAT["$cat"]=$((${COUNT_BY_CAT[$cat]:-0} + 1))
	SIZE_BY_CAT["$cat"]=$((${SIZE_BY_CAT[$cat]:-0} + size))
	MOVED_COUNT=$((MOVED_COUNT + 1))
	MOVED_BYTES=$((MOVED_BYTES + size))
}

human_size() {
	local b=$1
	if ((b < 1024)); then
		printf '%d B' "$b"
	elif ((b < 1048576)); then
		printf '%d.%d KiB' "$((b / 1024))" "$(((b % 1024) * 10 / 1024))"
	elif ((b < 1073741824)); then
		printf '%d.%d MiB' "$((b / 1048576))" "$(((b % 1048576) * 10 / 1048576))"
	else
		printf '%d.%d GiB' "$((b / 1073741824))" "$(((b % 1073741824) * 10 / 1073741824))"
	fi
}

print_summary() {
	local cat
	local -a keys=()

	if ((MOVED_COUNT == 0 && DUP_SKIPPED == 0 && DUP_DELETED == 0 && DUP_MOVED == 0)); then
		printf 'Nothing to organize.\n'
		return 0
	fi

	if [[ $DRY_RUN -eq 1 ]]; then
		printf '\nSummary (dry run):\n'
	else
		printf '\nSummary:\n'
	fi

	if ((${#COUNT_BY_CAT[@]} > 0)); then
		keys=("${!COUNT_BY_CAT[@]}")
		while IFS= read -r cat; do
			printf '  %-20s %6d files  %s\n' "$cat" "${COUNT_BY_CAT[$cat]}" "$(human_size "${SIZE_BY_CAT[$cat]}")"
		done < <(printf '%s\n' "${keys[@]}" | sort)
	fi
	printf '  %-20s %6d files  %s\n' "Total" "$MOVED_COUNT" "$(human_size "$MOVED_BYTES")"

	if [[ $DEDUPE -eq 1 ]]; then
		printf 'Duplicates: %d skipped, %d moved, %d deleted\n' "$DUP_SKIPPED" "$DUP_MOVED" "$DUP_DELETED"
	fi
}

if [[ $UNDO -eq 1 ]]; then
	undo_last
	exit 0
fi

if [[ -n $RULES_FILE ]]; then
	rules_to_load=$RULES_FILE
else
	rules_to_load=""
	if [[ -n ${XDG_CONFIG_HOME:-} ]]; then
		rules_to_load=$XDG_CONFIG_HOME/organize/rules.conf
	elif [[ -n ${HOME:-} ]]; then
		rules_to_load=$HOME/.config/organize/rules.conf
	fi
fi

if [[ -n $rules_to_load && -f $rules_to_load ]]; then
	RULES_PATH=$(cd -- "$(dirname -- "$rules_to_load")" && pwd)/$(basename -- "$rules_to_load")
	load_rules "$RULES_PATH"
elif [[ -n $RULES_FILE ]]; then
	die "rules file not found: $RULES_FILE"
fi

if [[ $DEDUPE -eq 1 ]]; then
	if [[ $DUP_MODE == move ]]; then
		add_managed_dir Duplicates
	fi
	build_dedupe_index
fi

should_skip() {
	local src=$1 name
	name=$(basename -- "$src")
	[[ $src -ef $SCRIPT_PATH ]] && return 0
	[[ -n $RULES_PATH && $src -ef $RULES_PATH ]] && return 0
	[[ $name == .organize-log-*.log ]] && return 0
	[[ $INCLUDE_HIDDEN -eq 0 ]] && is_hidden_name "$name" && return 0
	return 1
}

files=()

if [[ $RECURSIVE -eq 1 ]]; then
	prune=()
	add_prune() {
		if ((${#prune[@]} > 0)); then
			prune+=(-o)
		fi
		prune+=("$@")
	}

	if [[ $TARGET != "$DIR" && $TARGET == "$DIR"/* ]]; then
		add_prune -path "$TARGET"
	fi
	for cat in "${CATEGORIES[@]}"; do
		add_prune -path "$TARGET/$cat"
	done
	# Never descend into hidden directories when hidden files are excluded.
	if [[ $INCLUDE_HIDDEN -eq 0 ]]; then
		add_prune -name '.*'
	fi

	while IFS= read -r -d '' src; do
		should_skip "$src" && continue
		files+=("$src")
	done < <(find "$DIR" -mindepth 1 \( "${prune[@]}" \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null)
else
	while IFS= read -r -d '' src; do
		should_skip "$src" && continue
		files+=("$src")
	done < <(find "$DIR" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
fi

if ((${#files[@]} > 0)); then
	for src in "${files[@]}"; do
		[[ -e $src || -L $src ]] || continue
		base=$(basename -- "$src")
		ext=""
		[[ $base != .* && $base == *.* ]] && ext=${base##*.}

		tv_matched=0
		if cat=$(rule_for "$base"); then
			:
		else
			cat=$(category_for "$ext")
			if [[ $TV_MODE -eq 1 && $cat == Videos ]] && tv_cat=$(tv_category "$src"); then
				cat=$tv_cat
				tv_matched=1
			fi
		fi

		if [[ $BY_DATE -eq 1 && $tv_matched -eq 0 ]]; then
			date_dir=$(date_path "$src" "$cat" 2>/dev/null || true)
			if [[ -n $date_dir ]]; then
				cat=$cat/$date_dir
			fi
		fi

		if [[ $DEDUPE -eq 1 ]]; then
			DUP_MATCH=""
			if find_duplicate "$src"; then
				handle_duplicate "$src" "$DUP_MATCH"
				continue
			fi
		fi

		move_one "$src" "$cat"

		if [[ $DEDUPE -eq 1 ]]; then
			SEEN_HASH["$CUR_SIZE:$CUR_HASH"]=${LAST_DEST:-$src}
		fi
	done
fi

if [[ $MOVE_FOLDERS -eq 1 && $RECURSIVE -eq 0 ]]; then
	while IFS= read -r -d '' src; do
		[[ $src == "$TARGET" ]] && continue
		should_skip "$src" && continue
		is_category=0
		for cat in "${CATEGORIES[@]}"; do
			[[ $src == "$TARGET/$cat" ]] && is_category=1
		done
		[[ $is_category -eq 1 ]] && continue
		move_one "$src" Folders 1
	done < <(find "$DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

if [[ -n $LOG ]]; then
	printf 'Log: %s (use --undo to revert)\n' "$LOG"
fi

print_summary
