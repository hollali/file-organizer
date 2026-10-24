#!/usr/bin/env bash
#
# organize.sh - sort files and folders into category folders.
#
# Features: extension categories, TV grouping, date sorting, custom rules,
# duplicate detection, dry-run, undo, and a summary report.
#
# Usage: ./organize.sh [options] [directory]
#

VERSION="1.1.0"

set -euo pipefail

SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")

DRY_RUN=0
RECURSIVE=0
MOVE_FOLDERS=0
INCLUDE_HIDDEN=0
UNDO=0
TV_MODE=0
MUSIC_MODE=0
SMART_MODE=0
BY_DATE=0
DEDUPE=0
DUP_MODE=skip
RENAME=0
LINK=0
JSON=0
RULES_FILE=""
RULES_PATH=""
TARGET=""
DIR=""
MIN_SIZE=""
MAX_SIZE=""
OLDER_THAN=""
SCHEDULE=""
SCHEDULE_DIR=""
SCHEDULE_HOUR=""
SCHEDULE_MIN=""
SCHEDULE_DAYS=""

CATEGORIES=(Images Documents Videos Audio Archives "Disk Images" Code Fonts Executables Other Folders)

RULE_PATTERNS=()
RULE_DESTS=()
CAT_EXT_NAMES=()
CAT_EXT_LISTS=()
INCLUDE_PATTERNS=()
EXCLUDE_PATTERNS=()
CONFIG_ARGS=()
declare -A SIZE_INDEX=()
declare -A HASH_CACHE=()
declare -A SEEN_HASH=()
declare -A COUNT_BY_CAT=()
declare -A SIZE_BY_CAT=()
declare -A SMART_DEST=()

SMART_SHOW=""
SMART_SEASON=""
SMART_TITLE=""
SMART_YEAR=""

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
DUP_TRASHED=0
UNSCHEDULE=0

usage() {
	cat <<EOF
Usage: organize.sh [options] [directory] (v${VERSION})

Sort files in DIRECTORY (default: .) into category folders.

Videos are handled specially: episodes are organized as Show/Season NN/ and
unrecognized videos (movies, samples, clips) are left in place, so no generic
Videos/ dump folder is ever created (TV mode uses Videos/Show/Season NN/).

Options:
  -t, --target DIR   Move files into DIR instead of organizing in place
  -r, --recursive    Include files in subdirectories (moved to DIRECTORY/category)
  -F, --folders      Also move top-level subdirectories into Folders/
  -T, --tv           Group TV episodes as Videos/Show/Season NN/;
                     unrecognized videos stay in place
  -M, --music        Group tracks as Audio/Artist/Album/ (tags or "Artist - Album - N - Title")
      --smart        Smart media mode: recursively inspect every file and folder,
                     then build Show/Season NN/, Movies/Title (Year)/,
                     Audio/Artist/Album/, date folders in ~/Pictures, and
                     type folders in ~/Documents (XDG user dirs).
                     Nested images/documents keep their meaningful source
                     folder as an album/context subfolder (~/Pictures/<context>,
                     ~/Documents/<context>); generic names are ignored.
                     Reuses existing folders, moves related subtitles/artwork,
                     never overwrites, and leaves unidentified files in place.
      --media        Alias for --smart
  -H, --hidden       Include hidden files
  -n, --dry-run      Show what would happen without moving anything
  -u, --undo         Undo the most recent run in the given directory
      --by-date      Group files as Category/YYYY/MM/
      --dedupe       Skip files identical to ones already organized
      --duplicates M Handle duplicates: skip (default), delete, move, or trash
      --trash        Shorthand for --duplicates trash (moves dups to the system trash)
  -i, --include G    Only organize files whose name matches glob G (repeatable)
  -x, --exclude G    Skip files whose name matches glob G (repeatable)
      --min-size S   Skip files smaller than S (bytes, or K/M/G suffix)
      --max-size S   Skip files larger than S (bytes, or K/M/G suffix)
      --older-than N Only organize files not modified in the last N days
      --rename       Normalize names while moving: lowercase, spaces to underscores
  -l, --link         Leave a symlink at the original path pointing at the new location
      --rules FILE   Load custom rules (default: ~/.config/organize/rules.conf)
      --config FILE  Load default flags from FILE (default: ~/.config/organize/config.conf)
      --json         Print the summary as JSON
      --version      Show version and exit
      --doctor       Check for required and optional dependencies
      --install-deps Attempt to install missing dependencies (requires sudo)
      --schedule TIME[D@DIR] Schedule to run daily at TIME (HH:MM) for DIR (e.g. 09:00@~/Downloads)
      --unschedule   Remove scheduled cron job
  -h, --help         Show this help
EOF
}

die() {
	printf 'organize: %s\n' "$*" >&2
	exit 1
}

parse_size() {
	local s=$1 n unit
	[[ $s =~ ^([0-9]+)([kKmMgG]?)$ ]] || die "invalid size: $s (use bytes or K/M/G suffix)"
	n=${BASH_REMATCH[1]}
	unit=${BASH_REMATCH[2]}
	case $unit in
	k | K) n=$((n * 1024)) ;;
	m | M) n=$((n * 1048576)) ;;
	g | G) n=$((n * 1073741824)) ;;
	esac
	printf '%s' "$n"
}

percent_encode() {
	local s=$1 out="" c i
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		case $c in
		[a-zA-Z0-9.~_/-]) out+=$c ;;
		*)
			printf -v c '%%%02X' "'$c"
			out+=$c
			;;
		esac
	done
	printf '%s' "$out"
}

load_default_config() {
	local file=$1 line
	local -a words=()
	[[ -f $file ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%%#*}
		read -r -a words <<<"$line"
		((${#words[@]} > 0)) || continue
		CONFIG_ARGS+=("${words[@]}")
	done <"$file"
}

CONFIG_CLI=""
prev_arg=""
for arg in "$@"; do
	[[ $prev_arg == --config ]] && CONFIG_CLI=$arg
	prev_arg=$arg
done

config_path=""
if [[ -n $CONFIG_CLI ]]; then
	config_path=$CONFIG_CLI
elif [[ -n ${XDG_CONFIG_HOME:-} ]]; then
	config_path=$XDG_CONFIG_HOME/organize/config.conf
elif [[ -n ${HOME:-} ]]; then
	config_path=$HOME/.config/organize/config.conf
fi
if [[ -n $config_path ]]; then
	if [[ -f $config_path ]]; then
		load_default_config "$config_path"
		expect_value=0
		for w in "${CONFIG_ARGS[@]}"; do
			if ((expect_value)); then
				expect_value=0
				continue
			fi
			case $w in
			--target | -t | --duplicates | --rules | --config | --include | -i | --exclude | -x | --min-size | --max-size | --older-than)
				expect_value=1
				;;
			-*)
				;;
			*)
				die "config: only options are allowed: $w"
				;;
			esac
		done
		if ((${#CONFIG_ARGS[@]} > 0)); then
			set -- "${CONFIG_ARGS[@]}" "$@"
		fi
	elif [[ -n $CONFIG_CLI ]]; then
		die "config file not found: $CONFIG_CLI"
	fi
fi

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
	-M | --music)
		MUSIC_MODE=1
		shift
		;;
	--smart | --media)
		SMART_MODE=1
		RECURSIVE=1
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
	-i | --include)
		(($# >= 2)) || die "option $1 requires an argument"
		INCLUDE_PATTERNS+=("$2")
		shift 2
		;;
	-x | --exclude)
		(($# >= 2)) || die "option $1 requires an argument"
		EXCLUDE_PATTERNS+=("$2")
		shift 2
		;;
	--min-size)
		(($# >= 2)) || die "option $1 requires an argument"
		MIN_SIZE=$(parse_size "$2")
		shift 2
		;;
	--max-size)
		(($# >= 2)) || die "option $1 requires an argument"
		MAX_SIZE=$(parse_size "$2")
		shift 2
		;;
	--older-than)
		(($# >= 2)) || die "option $1 requires an argument"
		[[ $2 =~ ^[0-9]+$ ]] || die "invalid days: $2 (use a whole number)"
		OLDER_THAN=$2
		shift 2
		;;
	--rename)
		RENAME=1
		shift
		;;
	-l | --link)
		LINK=1
		shift
		;;
	--json)
		JSON=1
		shift
		;;
	--version)
		echo "organize.sh ${VERSION}"
		exit 0
		;;
	--doctor)
		(
			printf 'organize.sh %s - dependency check\n\n' "$VERSION"
			ok=0; warn=0
			if command -v bash >/dev/null && bash --version | grep -q 'version [4-9]\|version 10'; then
				printf '  [OK] bash %s\n' "$(bash --version | head -n1 | awk '{print $4}')"
				ok=$((ok + 1))
			else
				printf '  [WARN] bash version may be too old (need >= 4)\n'
				warn=$((warn + 1))
			fi
			for cmd in find mv mkdir rm basename dirname date tr stat sort sha256sum; do
				if command -v "$cmd" >/dev/null 2>&1; then
					printf '  [OK] %s\n' "$cmd"
					ok=$((ok + 1))
				else
					printf '  [WARN] %s not found\n' "$cmd"
					warn=$((warn + 1))
				fi
			done
			if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || command -v sha256 >/dev/null 2>&1; then
				printf '  [OK] SHA256 available (for --dedupe)\n'
				ok=$((ok + 1))
			else
				printf '  [WARN] No SHA256 tool found (required for --dedupe)\n'
				warn=$((warn + 1))
			fi
			if command -v exiftool >/dev/null 2>&1; then
				printf '  [OK] exiftool (optional, for EXIF dates/music tags)\n'
				ok=$((ok + 1))
			else
				printf '  [INFO] exiftool not found (optional)\n'
			fi
			printf '\nSummary: %d ok, %d warnings/info\n' "$ok" "$warn"
			if [[ $warn -eq 0 ]]; then
				printf 'All required dependencies look good!\n'
			else
				printf 'Some optional/missing deps detected - see above.\n'
			fi
		)
		exit 0
		;;
	--schedule)
		(($# >= 2)) || die "option $1 requires an argument"
		SCHEDULE=$2
		shift 2
		;;
	--unschedule)
		UNSCHEDULE=1
		shift
		;;
	--install-deps)
		(
			printf 'organize.sh %s - installing missing dependencies\n\n' "$VERSION"
			to_install=()
			need_sudo=0
			command -v bash >/dev/null || to_install+=(bash)
			command -v find >/dev/null || to_install+=(findutils)
			command -v stat >/dev/null || to_install+=(coreutils)
			command -v sha256sum >/dev/null && command -v shasum >/dev/null && command -v sha256 >/dev/null || true
			if ! command -v sha256sum >/dev/null && ! command -v shasum >/dev/null && ! command -v sha256 >/dev/null; then
				to_install+=(coreutils)
			fi
			if ! command -v exiftool >/dev/null; then
				to_install+=(libimage-exiftool-perl)
			fi
			if ((${#to_install[@]} == 0)); then
				printf 'All dependencies already installed.\n'
				exit 0
			fi
			printf 'Packages to install: %s\n' "${to_install[*]}"
			if command -v apt-get >/dev/null; then
				printf 'Detected: Debian/Ubuntu (apt)\n'
				sudo apt-get update -qq
				sudo apt-get install -y "${to_install[@]/libimage-exiftool-perl/libimage-exiftool-perl}"
			elif command -v dnf >/dev/null; then
				printf 'Detected: Fedora/RHEL (dnf)\n'
				sudo dnf install -y perl-Image-ExifTool
			elif command -v yum >/dev/null; then
				printf 'Detected: RHEL/CentOS (yum)\n'
				sudo yum install -y perl-Image-ExifTool
			elif command -v pacman >/dev/null; then
				printf 'Detected: Arch/Manjaro (pacman)\n'
				sudo pacman -S --noconfirm perl-image-exiftool bash findutils coreutils
			elif command -v zypper >/dev/null; then
				printf 'Detected: openSUSE (zypper)\n'
				sudo zypper install -y perl-Image-ExifTool
			elif command -v apk >/dev/null; then
				printf 'Detected: Alpine (apk)\n'
				sudo apk add bash findutils coreutils exiftool
			elif command -v brew >/dev/null; then
				printf 'Detected: macOS (brew)\n'
				brew install exiftool
			else
				printf 'Could not detect package manager. Install manually.\n'
				exit 1
			fi
			printf '\nDone.\n'
		)
		exit 0
		;;
	--trash)
		DUP_MODE=trash
		DEDUPE=1
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
		skip | delete | move | trash)
			DUP_MODE=$2
			;;
		*)
			die "invalid duplicate mode: $2 (use skip, delete, move, or trash)"
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
	--config)
		# Value is consumed by the pre-scan above; just skip past it here.
		(($# >= 2)) || die "option $1 requires an argument"
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
		if [[ -L $src && $src -ef $dest ]]; then
			rm -f -- "$src"
		elif [[ -e $src ]]; then
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

# Turn a name into a single safe path component: no slashes, trimmed,
# dots and underscores become spaces, repeated spaces collapsed.
sanitize_component() {
	local s=$1
	s=${s//\//}
	s=${s//./ }
	s=${s//_/ }
	while [[ $s == *"  "* ]]; do
		s=${s//  / }
	done
	s=${s#"${s%%[! ]*}"}
	s=${s%"${s##*[! ]}"}
	printf '%s' "$s"
}

# Print the relative folder for a track as Audio/Artist/Album, using tags
# when exiftool is present and an "Artist - Album - NN - Title" filename
# otherwise. Fails when no artist can be determined.
music_category() {
	local src=$1 base artist="" album=""
	local re='^(.+)[ ]-[ ](.+)[ ]-[ ]{0,1}[0-9]{1,3}[ ]-[ ](.+)$'

	if command -v exiftool >/dev/null 2>&1; then
		artist=$(exiftool -s3 -Artist "$src" 2>/dev/null || true)
		album=$(exiftool -s3 -Album "$src" 2>/dev/null || true)
	fi

	base=$(basename -- "$src")
	if [[ -z $artist || -z $album ]] && [[ $base =~ $re ]]; then
		[[ -z $artist ]] && artist=${BASH_REMATCH[1]}
		[[ -z $album ]] && album=${BASH_REMATCH[2]}
	fi

	artist=$(sanitize_component "$artist")
	album=$(sanitize_component "$album")
	[[ -n $artist ]] || return 1

	if [[ -n $album ]]; then
		printf 'Audio/%s/%s\n' "$artist" "$album"
	else
		printf 'Audio/%s\n' "$artist"
	fi
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

rename_basename() {
	local name=$1 base ext
	if [[ $name != .* && $name == *.* ]]; then
		base=${name%.*}
		ext=.${name##*.}
	else
		base=$name
		ext=""
	fi
	base=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
	ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
	base=${base// /_}
	while [[ $base == *__* ]]; do
		base=${base//__/_}
	done
	base=${base#_}
	base=${base%_}
	[[ -n $base ]] || {
		printf '%s' "$name"
		return
	}
	printf '%s%s' "$base" "$ext"
}

# Resolve an XDG user directory (Pictures, Documents) without depending on
# xdg-user-dir being installed. Honors the environment variable first, then
# the tool, then the conventional ~/Name fallback.
xdg_user_dir() {
	local key=$1 fallback=$2 var val
	case $key in
	PICTURES) var=XDG_PICTURES_DIR ;;
	DOCUMENTS) var=XDG_DOCUMENTS_DIR ;;
	VIDEOS) var=XDG_VIDEOS_DIR ;;
	MUSIC) var=XDG_MUSIC_DIR ;;
	*) var="" ;;
	esac
	if [[ -n $var ]]; then
		val=${!var:-}
		if [[ -n $val ]]; then
			printf '%s' "$val"
			return 0
		fi
	fi
	if command -v xdg-user-dir >/dev/null 2>&1; then
		val=$(xdg-user-dir "$key" 2>/dev/null || true)
		if [[ -n $val && $val != "$HOME" ]]; then
			printf '%s' "$val"
			return 0
		fi
	fi
	printf '%s/%s' "$HOME" "$fallback"
}

# Find an existing child directory of PARENT whose name equals WANT, ignoring
# case, so a library never gains a second folder that differs only in case.
# Prints the resolved absolute path (whether or not it exists yet).
resolve_child_dir() {
	local parent=$1 want=$2 d base
	[[ -d $parent ]] || {
		printf '%s/%s\n' "$parent" "$want"
		return
	}
	shopt -s nullglob
	for d in "$parent"/*/; do
		base=${d%/}
		base=${base##*/}
		shopt -s nocasematch
		if [[ $base == "$want" ]]; then
			shopt -u nocasematch
			shopt -u nullglob
			printf '%s\n' "${d%/}"
			return
		fi
		shopt -u nocasematch
	done
	shopt -u nullglob
	printf '%s/%s\n' "$parent" "$want"
}

# Resolve a season folder for a show, reusing "Season 1", "Season 01", "S01",
# or "Series 1" instead of creating a second folder for the same season.
resolve_season_dir() {
	local parent=$1 season=$2 d base s
	shopt -s nullglob
	for d in "$parent"/*/; do
		base=${d%/}
		base=${base##*/}
		if s=$(season_from_folder "$base") && [[ $s == "$season" ]]; then
			shopt -u nullglob
			printf '%s\n' "${d%/}"
			return
		fi
	done
	shopt -u nullglob
	printf '%s/Season %02d\n' "$parent" "$season"
}

# Resolve a slash-separated relative destination under TARGET, reusing any
# existing case-insensitive matches. Prints the relative path.
resolve_rel_dir() {
	local rel=$1 cur=$TARGET comp
	local -a parts=()
	IFS=/ read -r -a parts <<<"$rel"
	for comp in "${parts[@]}"; do
		[[ -n $comp ]] || continue
		cur=$(resolve_child_dir "$cur" "$comp")
	done
	if [[ $cur == "$TARGET" ]]; then
		printf '.\n'
	elif [[ $cur == "$TARGET"/* ]]; then
		printf '%s\n' "${cur#"$TARGET"/}"
	else
		printf '%s\n' "$rel"
	fi
}

# Strip grouping tags, normalize separators and reject empty names.
smart_show_name() {
	local s
	s=$(clean_show_name "$1")
	while [[ $s == *'['*']'* ]]; do
		s="${s%%\[*} ${s#*\]}"
	done
	while [[ $s == *'('*')'* ]]; do
		s="${s%%\(*} ${s#*\)}"
	done
	s=$(sanitize_component "$s")
	printf '%s' "$s"
}

# Return the season number when NAME is a season folder such as
# "Season 1", "Season 01", "S01", or "Series 2".
season_from_folder() {
	local name=$1
	local re_season='^[Ss]eason[._ -]*([0-9]{1,2})$'
	local re_series='^[Ss]eries[._ -]*([0-9]{1,2})$'
	local re_short='^[Ss]([0-9]{1,2})$'
	if [[ $name =~ $re_season ]]; then
		printf '%s' "$((10#${BASH_REMATCH[1]}))"
		return 0
	fi
	if [[ $name =~ $re_series ]]; then
		printf '%s' "$((10#${BASH_REMATCH[1]}))"
		return 0
	fi
	if [[ $name =~ ^[Ss]([0-9]{1,2})$ ]]; then
		printf '%s' "$((10#${BASH_REMATCH[1]}))"
		return 0
	fi
	return 1
}

# Set SMART_SHOW and SMART_SEASON when SRC is an identifiable TV episode.
# Seasons and shows may come from the filename or from ancestor folders.
# Returns non-zero when the file cannot be identified confidently.
detect_episode() {
	local src=$1 base dir cur name parent show="" season=""
	local re_sxx re_nxn re_season_ep re_season re_s re_ep re_ep_bare re_episode re_dash re_numeric
	local re_anc_season='^(.+)[._ -]+[sS]eason[._ -]*([0-9]{1,2})$'
	local re_anc_series='^(.+)[._ -]+[sS]eries[._ -]*([0-9]{1,2})$'
	local bare_numeric=0

	base=$(basename -- "$src")
	base=${base%.*}

	re_sxx='^(.+)[._ -]+[sS]([0-9]{1,2})[._ -]*[eE]([0-9]{1,3})([^0-9]|$)'
	re_nxn='^(.+)[._ -]+([0-9]{1,2})[xX]([0-9]{1,3})([^0-9]|$)'
	re_season_ep='^(.+)[._ -]+[sS]eason[._ -]*([0-9]{1,2})[._ -]*([eE]pisode|[eE][pP]?)[._ -]*([0-9]{1,4})([^0-9]|$)'
	re_season='^(.+)[._ -]+[sS]eason[._ -]*([0-9]{1,2})([^0-9]|$)'
	re_s='^(.+)[._ -]+[sS]([0-9]{1,2})([^0-9]|$)'
	re_ep='^(.+)[._ -]+[eE][pP]?[._ -]?([0-9]{1,4})([^0-9]|$)'
	re_ep_bare='^[eE][pP]?[._ -]?([0-9]{1,4})([^0-9]|$)'
	re_episode='^[eE]pisode[._ -]*([0-9]{1,4})([^0-9]|$)'
	re_dash='^(.+)[._ -]+-[._ -]+([0-9]{1,4})[._ -]+'
	re_numeric='^[0-9]{1,4}([^0-9]|$)'

	if [[ $base =~ $re_sxx ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	elif [[ $base =~ $re_nxn ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	elif [[ $base =~ $re_season_ep ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	elif [[ $base =~ $re_ep ]]; then
		show=${BASH_REMATCH[1]}
	elif [[ $base =~ $re_dash ]]; then
		show=${BASH_REMATCH[1]}
	elif [[ $base =~ $re_episode ]]; then
		:
	elif [[ $base =~ $re_season ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	elif [[ $base =~ $re_s ]]; then
		show=${BASH_REMATCH[1]}
		season=${BASH_REMATCH[2]}
	elif [[ $base =~ $re_ep_bare ]]; then
		:
	elif [[ $base =~ $re_numeric ]]; then
		bare_numeric=1
	else
		return 1
	fi

	if ((bare_numeric)); then
		show=""
	fi

	# Walk up the folder tree for missing show/season context.
	cur=$(dirname -- "$src")
	while [[ $cur == "$DIR"/* ]]; do
		name=$(basename -- "$cur")
		if [[ -z $season ]] && season=$(season_from_folder "$name"); then
			:
		fi
		if [[ -z $show && $name =~ $re_anc_season ]]; then
			show=${BASH_REMATCH[1]}
			[[ -z $season ]] && season=$((10#${BASH_REMATCH[2]}))
		fi
		if [[ -z $show && $name =~ $re_anc_series ]]; then
			show=${BASH_REMATCH[1]}
			[[ -z $season ]] && season=$((10#${BASH_REMATCH[2]}))
		fi
		if [[ -n $season && -z $show ]]; then
			parent=$(dirname -- "$cur")
			if [[ $parent != "$DIR" ]]; then
				show=$(basename -- "$parent")
			fi
		fi
		[[ -n $show && -n $season ]] && break
		cur=$(dirname -- "$cur")
	done

	show=$(smart_show_name "$show")
	[[ -n $show ]] || return 1
	[[ -n $season ]] || return 1
	[[ $season =~ ^[0-9]+$ ]] || return 1

	SMART_SHOW=$show
	SMART_SEASON=$((10#$season))
	return 0
}

# Set SMART_TITLE and SMART_YEAR when SRC looks like a movie. Fails for
# generic names (sample, trailer, bare episode markers) to avoid guessing.
detect_movie() {
	local src=$1 base name year="" w lw out=""
	local -a words=()
	local re_year='^(19|20)[0-9]{2}$'
	local re_ep_marker='[._ -][eE][pP]?[._ -]?[0-9]{1,4}([._ -]|$)'

	base=$(basename -- "$src")
	base=${base%.*}

	# Bare episode markers are not movies.
	if [[ $base =~ $re_ep_marker ]]; then
		return 1
	fi
	if [[ $base =~ ^[^-]+[[:space:]]-[[:space:]][0-9]{1,4}[[:space:]]-[[:space:]] ]]; then
		return 1
	fi

	name=${base//./ }
	name=${name//_/ }

	while [[ $name == *'['*']'* ]]; do
		local pre=${name%%\[*} rest=${name#*\[} inner=${rest%%\]*} post=${rest#*\]}
		if [[ $inner =~ $re_year ]]; then
			year=$inner
		fi
		name="$pre $post"
	done
	while [[ $name == *'('*')'* ]]; do
		local pre=${name%%\(*} rest=${name#*\(} inner=${rest%%\)*} post=${rest#*\)}
		if [[ $inner =~ $re_year ]]; then
			year=$inner
		fi
		name="$pre $post"
	done
	name=$(trim "$name")
	read -r -a words <<<"$name"
	for w in "${words[@]}"; do
		lw=${w,,}
		lw=${lw//[^a-z0-9]/}
		if [[ $lw =~ $re_year ]]; then
			year=$lw
			continue
		fi
		case $lw in
		"" | 480p | 576p | 720p | 1080p | 2160p | 4k | uhd | hdr | sdr | 10bit | 8bit | \
			bluray | blu | brrip | bdrip | webrip | webdl | web | hdtv | dvdrip | dvd | \
			hdcam | cam | ts | x264 | x265 | h264 | h265 | hevc | avc | aac | ac3 | eac3 | \
			dts | dd | ddp | truehd | atmos | remux | proper | repack | extended | unrated | \
			directors | cut | multi | dual | sub | subs | dubbed | hardsub | softsub)
			continue
			;;
		esac
		out+=" $w"
	done
	out=$(trim "$out")
	out=$(sanitize_component "$out")
	[[ -n $out ]] || return 1
	[[ $out =~ [A-Za-z] ]] || return 1
	lw=${out,,}
	case $lw in
	sample | trailer | teaser | movie | video | film | clip | download | file | \
		unknown | untitled | output | temp | tmp | final)
		return 1
		;;
	esac

	SMART_TITLE=$out
	SMART_YEAR=$year
	return 0
}

# Normalized key used to bundle subtitles, nfo files and artwork with the
# video they belong to. Strips extensions, language/forced/sdh suffix tokens.
assoc_key() {
	local name=$1 lw
	local re_lang='[._ -]([A-Za-z]{2,3})$'
	local re_token='[._ -]([A-Za-z0-9]{2,10})$'
	name=${name%.*}
	while [[ $name =~ $re_lang ]]; do
		lw=${BASH_REMATCH[1],,}
		case $lw in
		en | eng | english | ar | ara | arabic | fr | fre | fra | french | es | spa | spanish | \
			de | ger | deu | german | it | ita | italian | pt | por | portuguese | ru | rus | russian | \
			nl | dut | dutch | pl | pol | polish | tr | tur | turkish | hi | hin | hindi | \
			ja | jpn | japanese | ko | kor | korean | zh | chi | chs | cht | chinese | \
			forced | sdh | cc | hi)
			name=${name%"${BASH_REMATCH[0]}"}
			;;
		*)
			break
			;;
		esac
	done
	while [[ $name =~ $re_token ]]; do
		lw=${BASH_REMATCH[1],,}
		case $lw in
		480p | 576p | 720p | 1080p | 2160p | 4k | uhd | hdr | sdr | 10bit | 8bit | \
			bluray | blu | brrip | bdrip | webrip | webdl | web | hdtv | dvdrip | dvd | \
			hdcam | cam | x264 | x265 | h264 | h265 | hevc | avc | aac | ac3 | eac3 | \
			dts | dd | ddp | truehd | atmos | remux | proper | repack | extended | unrated | \
			directors | cut | multi | dual | hardsub | softsub | dubbed | \
			thumb | thumbnail | poster | fanart | banner | backdrop | logo | clearart | disc)
			name=${name%"${BASH_REMATCH[0]}"}
			;;
		*)
			break
			;;
		esac
	done
	name=${name,,}
	name=${name//[^a-z0-9]/}
	printf '%s' "$name"
}

# Return 0 for subtitle/nfo files and for generic artwork names that are
# likely to belong to the video in the same folder.
is_sidecar_file() {
	local base ext stem
	base=$(basename -- "$1")
	ext=""
	[[ $base != .* && $base == *.* ]] && ext=${base##*.}
	ext=${ext,,}
	stem=${base%.*}
	stem=${stem,,}
	case $ext in
	srt | ass | ssa | vtt | sub | idx | smi | nfo | sfv) return 0 ;;
	esac
	case $stem in
	poster | folder | cover | fanart | thumb | thumbnail | banner | backdrop | logo | clearart | disc | landscape)
		return 0
		;;
	esac
	return 1
}

# Canonical relative destination for an episode. Series live directly under
# the target so one show is one folder (no generic Videos wrapper).
series_rel() {
	local show=$1 season=$2 cur
	cur=$(resolve_child_dir "$TARGET" "$show")
	cur=$(resolve_season_dir "$cur" "$season")
	printf '%s\n' "${cur#"$TARGET"/}"
}

# Canonical relative destination for a movie.
movie_rel() {
	local title=$1 year=$2 name cur
	if [[ -n $year ]]; then
		name="$title ($year)"
	else
		name=$title
	fi
	cur=$(resolve_child_dir "$TARGET" Movies)
	cur=$(resolve_child_dir "$cur" "$name")
	printf '%s\n' "${cur#"$TARGET"/}"
}

document_type_dir() {
	local ext
	ext=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	case $ext in
	pdf) echo PDF ;;
	doc | docx | odt | rtf | txt | md | markdown | pages) echo Text ;;
	xls | xlsx | ods | csv | numbers) echo Spreadsheets ;;
	ppt | pptx | odp | key) echo Presentations ;;
	epub | mobi | azw3 | fb2) echo Ebooks ;;
	*) echo "$(printf '%s' "$ext" | tr '[:lower:]' '[:upper:]')" ;;
	esac
}

# Uppercased name, non-alphanumeric characters folded to single spaces.
normalized_name() {
	local lw
	lw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	lw=$(printf '%s' "$lw" | tr -c '[:alnum:]' ' ')
	while [[ $lw == *"  "* ]]; do
		lw=${lw//  / }
	done
	trim "$lw"
}

# Single membership test for context names; see is_generic_context_name.
name_is_generic() {
	local lw cat
	lw=$(normalized_name "$1")
	[[ -n $lw ]] || return 0

	for cat in "${CATEGORIES[@]}"; do
		[[ $(normalized_name "$cat") == "$lw" ]] && return 0
	done
	case $lw in
	movies | tv | duplicates) return 0 ;;
	esac

	[[ $lw =~ ^[0-9]+$ ]] && return 0
	[[ $lw =~ ^(19|20)[0-9]{2}$ ]] && return 0

	case $lw in
		image | images | photo | photos | photograph | photographs | picture | pictures | \
		pics | screenshot | screenshots | camera | wallpapers | wallpaper | memes | \
		document | documents | doc | docs | my\ documents | files | file | \
		download | downloads | desktop | music | audio | video | videos | \
		new\ folder | untitled | untitled\ folder | unknown | temp | tmp | \
		misc | others | other | stuff | random | media | backup | \
		scan | scans | scanned | to\ sort | sort | todo | inbox | general | mixed | various | \
		web\ download | torrent | torrent\ download)
		return 0
		;;
	esac
	return 1
}

# Ignore generic folder names, including duplicate suffixes such as
# "Photos 2" or "New Folder (2)".
is_generic_context_name() {
	local name=$1 re_dup_suffix='^(.+)[[:space:]]*[._ -]?[0-9]{1,3}$'
	name_is_generic "$name" && return 0
	[[ $name =~ $re_dup_suffix ]] || return 1
	name_is_generic "${BASH_REMATCH[1]}" && return 0
	return 1
}

# Print the closest meaningful ancestor folder of SRC (an ancestor below DIR,
# excluding DIR itself) for context-aware routing of images and documents.
# Generic names such as "Photos" or "New Folder" are skipped, so a file in
# "Rome Trip/Photos/" gets the context "Rome Trip". Prints nothing when no
# meaningful ancestor exists.
context_for() {
	local src=$1 cur name
	cur=$(dirname -- "$src")
	while [[ $cur == "$DIR"/* ]]; do
		name=$(basename -- "$cur")
		if ! is_generic_context_name "$name"; then
			printf '%s' "$name"
			return 0
		fi
		cur=$(dirname -- "$cur")
	done
	return 0
}

# Move a file into REL under TARGET, never overwriting. If an identical file
# already sits at the destination, treat it as a duplicate instead of adding
# a "name (1)" copy.
smart_move() {
	local src=$1 dest_dir=$2 label=${3:-} name dest
	name=$(basename -- "$src")
	if [[ $RENAME -eq 1 && ! -d $src ]]; then
		name=$(rename_basename "$name")
	fi
	dest=$dest_dir/$name
	if [[ $src -ef $dest ]]; then
		return 0
	fi
	if [[ -f $src && -f $dest ]] && cmp -s -- "$src" "$dest" 2>/dev/null; then
		handle_duplicate "$src" "$dest"
		return 0
	fi
	move_one "$src" "$dest_dir" 0 "$label"
}

# Remove folders emptied by smart mode, keeping directory categories intact.
prune_empty_source_dirs() {
	local d top cat skip
	[[ $DRY_RUN -eq 1 ]] && return 0
	while IFS= read -r -d '' d; do
		[[ $d == "$DIR" ]] && continue
		top=${d#"$DIR"/}
		top=${top%%/*}
		skip=0
		for cat in "${CATEGORIES[@]}"; do
			if [[ $SMART_MODE -eq 1 && ($cat == Images || $cat == Documents || $cat == Videos) ]]; then
				continue
			fi
			[[ $top == "$cat" ]] && skip=1
		done
		((skip == 1)) && continue
		[[ $TARGET != "$DIR" && ($d == "$TARGET" || $d == "$TARGET"/*) ]] && continue
		rmdir -- "$d" 2>/dev/null || true
	done < <(find "$DIR" -mindepth 1 -depth -type d -not -name '.*' -print0 2>/dev/null)
}

# Smart media organizer. Recursively inspects every file, groups episodes by
# show/season, movies by title/year, and other media by type, then moves
# related sidecar files (subtitles, nfo, artwork) with their video.
smart_organize() {
		local src base ext rel key cat date_dir name d abs_dir label dest_dir ctx
	local -A assoc=()
	local -A dir_dest=()
	local -A dir_ambig=()

	# Pass 1: identify videos so sidecar files can be matched regardless of
	# which one is encountered first.
	for src in "${files[@]}"; do
		[[ -e $src || -L $src ]] || continue
		base=$(basename -- "$src")
		ext=""
		[[ $base != .* && $base == *.* ]] && ext=${base##*.}
		[[ $(category_for "$ext") == Videos ]] || continue
		# Explicit rules and custom categories always win over smart detection.
		if rule_for "$base" >/dev/null; then
			continue
		fi
		if custom_category_for "$ext" >/dev/null; then
			continue
		fi

		if detect_episode "$src"; then
			rel=$(series_rel "$SMART_SHOW" "$SMART_SEASON")
		elif detect_movie "$src"; then
			rel=$(movie_rel "$SMART_TITLE" "$SMART_YEAR")
		else
			continue
		fi
		SMART_DEST[$src]=$rel
		d=$(dirname -- "$src")
		key=$(assoc_key "$base")
		# Key sidecar associations by source directory so identical stems in
		# different seasons can never cross-match.
		[[ -n $key ]] && assoc[${d}/${key}]=$rel
		if [[ -z ${dir_dest[$d]:-} ]]; then
			dir_dest[$d]=$rel
		elif [[ ${dir_dest[$d]} != "$rel" ]]; then
			dir_ambig[$d]=1
		fi
	done

	# Pass 2: move everything.
	for src in "${files[@]}"; do
		[[ -e $src || -L $src ]] || continue
		base=$(basename -- "$src")
		ext=""
		[[ $base != .* && $base == *.* ]] && ext=${base##*.}

		d=$(dirname -- "$src")
		abs_dir=""
		label=""
		if cat=$(rule_for "$base"); then
			rel=$cat
			label=${cat%%/*}
		elif [[ -n ${SMART_DEST[$src]:-} ]]; then
			rel=${SMART_DEST[$src]}
			label=Videos
			[[ $rel == Movies/* ]] && label=Movies
		else
			key=$(assoc_key "$base")
			if [[ -n $key && -n ${assoc[${d}/${key}]:-} ]]; then
				rel=${assoc[${d}/${key}]}
				label=Videos
				[[ $rel == Movies/* ]] && label=Movies
			elif is_sidecar_file "$src" && [[ -n ${dir_dest[$d]:-} ]]; then
				if [[ -n ${dir_ambig[$d]:-} ]]; then
					printf 'left in place (ambiguous sidecar): %s\n' "$src"
					continue
				fi
				rel=${dir_dest[$d]}
				label=Videos
				[[ $rel == Movies/* ]] && label=Movies
			else
				if is_sidecar_file "$src"; then
					printf 'left in place (no matching video for sidecar): %s\n' "$src"
					continue
				fi
				if cc=$(custom_category_for "$ext"); then
					cat=$cc
				else
					cat=$(category_for "$ext")
				fi
				case $cat in
				Videos)
					printf 'left in place (unidentified video): %s\n' "$src"
					continue
					;;
				Images)
					date_dir=$(date_path "$src" "$cat" 2>/dev/null || true)
					abs_dir=$(xdg_user_dir PICTURES Pictures)
					ctx=$(context_for "$src") || ctx=""
					[[ -n $ctx ]] && abs_dir=$abs_dir/$(sanitize_component "$ctx")
					[[ -n $date_dir ]] && abs_dir=$abs_dir/$date_dir
					label=Images
					;;
				Documents)
					abs_dir=$(xdg_user_dir DOCUMENTS Documents)
					ctx=$(context_for "$src") || ctx=""
					[[ -n $ctx ]] && abs_dir=$abs_dir/$(sanitize_component "$ctx")
					abs_dir=$abs_dir/$(document_type_dir "$ext")
					label=Documents
					;;
				Audio)
					if music_cat=$(music_category "$src"); then
						rel=$music_cat
					else
						rel=Audio
					fi
					label=Audio
					;;
				*)
					rel=$cat
					label=${cat%%/*}
					;;
				esac
				if [[ $BY_DATE -eq 1 && -z $abs_dir ]]; then
					date_dir=$(date_path "$src" "$rel" 2>/dev/null || true)
					[[ -n $date_dir ]] && rel=$rel/$date_dir
				fi
			fi
		fi

		if [[ -n $abs_dir ]]; then
			dest_dir=$abs_dir
		else
			rel=$(resolve_rel_dir "$rel")
			dest_dir=$TARGET/$rel
		fi
		if [[ $DEDUPE -eq 1 ]]; then
			DUP_MATCH=""
			if find_duplicate "$src"; then
				handle_duplicate "$src" "$DUP_MATCH"
				continue
			fi
		fi
		smart_move "$src" "$dest_dir" "$label"
		if [[ $DEDUPE -eq 1 ]]; then
			SEEN_HASH["$CUR_SIZE:$CUR_HASH"]=${LAST_DEST:-$src}
		fi
	done

	prune_empty_source_dirs
}

move_one() {
	local src=$1 cat=$2 is_dir=${3:-0} label=${4:-}
	local dest_dir dest size=0 name
	if [[ $cat == /* ]]; then
		dest_dir=$cat
	else
		dest_dir=$TARGET/$cat
	fi
	name=$(basename -- "$src")
	if [[ $RENAME -eq 1 && $is_dir -eq 0 ]]; then
		name=$(rename_basename "$name")
	fi
	dest=$(unique_path "$dest_dir/$name" "$is_dir")
	LAST_DEST=$dest

	if [[ $is_dir -eq 0 ]]; then
		size=$(file_size "$src" 2>/dev/null || printf 0)
	fi

	if [[ $DRY_RUN -eq 1 ]]; then
		if [[ $LINK -eq 1 ]]; then
			printf 'would move: %s -> %s (symlink left)\n' "$src" "$dest"
		else
			printf 'would move: %s -> %s\n' "$src" "$dest"
		fi
		record_move "$cat" "$size"
		return
	fi

	mkdir -p -- "$dest_dir"
	mv -- "$src" "$dest"
	if [[ $LINK -eq 1 ]]; then
		ln -s -- "$dest" "$src"
		printf 'moved: %s -> %s (symlink left)\n' "$src" "$dest"
	else
		printf 'moved: %s -> %s\n' "$src" "$dest"
	fi
	log_move "$src" "$dest"
	record_move "${label:-$cat}" "$size"
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
	local cat_name cat_exts
	local -a ext_arr=()
	[[ -f $file ]] || die "rules file not found: $file"

	while IFS= read -r line || [[ -n $line ]]; do
		lineno=$((lineno + 1))
		line=$(trim "$line")
		[[ -z $line || $line == \#* ]] && continue

		if [[ $line == @category* ]]; then
			line=${line#@category}
			line=$(trim "$line")
			if [[ $line == *'='* ]]; then
				cat_name=${line%%=*}
				cat_exts=${line#*=}
			elif [[ $line == *:* ]]; then
				cat_name=${line%%:*}
				cat_exts=${line#*:}
			else
				die "rules: $file:$lineno: expected '@category Name = ext ...'"
			fi
			cat_name=$(trim "$cat_name")
			cat_exts=$(trim "$cat_exts")
			[[ -n $cat_name ]] || die "rules: $file:$lineno: empty category name"
			[[ -n $cat_exts ]] || die "rules: $file:$lineno: empty extension list"
			if [[ $cat_name == */* || $cat_name == .* ]]; then
				die "rules: $file:$lineno: category name must not start with '.' or contain '/'"
			fi
			add_managed_dir "$cat_name"
			cat_exts=${cat_exts//,/ }
			# shellcheck disable=SC2206 # word splitting is intentional
			ext_arr=($cat_exts)
			((${#ext_arr[@]} > 0)) || die "rules: $file:$lineno: empty extension list"
			local i found=-1
			for ((i = 0; i < ${#CAT_EXT_NAMES[@]}; i++)); do
				[[ ${CAT_EXT_NAMES[i]} == "$cat_name" ]] && found=$i
			done
			if ((found >= 0)); then
				CAT_EXT_LISTS[found]+=" ${ext_arr[*]}"
			else
				CAT_EXT_NAMES+=("$cat_name")
				CAT_EXT_LISTS+=("${ext_arr[*]}")
			fi
			continue
		fi

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

# Match an extension against @category definitions; print the category name.
custom_category_for() {
	local ext=$1 i e
	((${#CAT_EXT_NAMES[@]} > 0)) || return 1
	ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
	for ((i = 0; i < ${#CAT_EXT_NAMES[@]}; i++)); do
		for e in ${CAT_EXT_LISTS[i]}; do
			if [[ $(printf '%s' "$e" | tr '[:upper:]' '[:lower:]') == "$ext" ]]; then
				printf '%s\n' "${CAT_EXT_NAMES[i]}"
				return 0
			fi
		done
	done
	return 1
}

match_any_glob() {
	local name=$1 g
	shift
	(($# > 0)) || return 1
	shopt -s nocasematch
	for g in "$@"; do
		# shellcheck disable=SC2053 # the right-hand side is intentionally a glob
		if [[ $name == $g ]]; then
			shopt -u nocasematch
			return 0
		fi
	done
	shopt -u nocasematch
	return 1
}

# Return 0 when the file should be left alone due to size or age filters.
file_filters_skip() {
	local src=$1 size mtime now
	if [[ -n $MIN_SIZE || -n $MAX_SIZE ]]; then
		size=$(file_size "$src" 2>/dev/null) || return 1
		[[ -n $MIN_SIZE && $size -lt $MIN_SIZE ]] && return 0
		[[ -n $MAX_SIZE && $size -gt $MAX_SIZE ]] && return 0
	fi
	if [[ -n $OLDER_THAN ]]; then
		mtime=$(stat -c %Y "$src" 2>/dev/null || true)
		[[ -z $mtime ]] && mtime=$(date -r "$src" +%s 2>/dev/null || true)
		if [[ -n $mtime ]]; then
			now=$(date +%s)
			((now - mtime < OLDER_THAN * 86400)) && return 0
		fi
	fi
	return 1
}

trash_file() {
	local src=$1 data_home tdir base dest info ts
	data_home=${XDG_DATA_HOME:-${HOME:?}/.local/share}
	tdir=$data_home/Trash
	mkdir -p -- "$tdir/files" "$tdir/info" || die "cannot create trash directory: $tdir"
	dest=$(unique_path "$tdir/files/$(basename -- "$src")")
	base=$(basename -- "$dest")
	info=$tdir/info/$base.trashinfo
	ts=$(date +%Y-%m-%dT%H:%M:%S)
	printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' "$(percent_encode "$src")" "$ts" >"$info"
	mv -- "$src" "$dest"
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
	trash)
		DUP_TRASHED=$((DUP_TRASHED + 1))
		if [[ $DRY_RUN -eq 1 ]]; then
			printf 'would trash duplicate: %s (matches %s)\n' "$src" "$match"
		else
			trash_file "$src"
			printf 'trashed duplicate: %s (matches %s)\n' "$src" "$match"
		fi
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

json_escape() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/\\n}
	s=${s//$'\t'/\\t}
	printf '%s' "$s"
}

print_summary_json() {
	local cat first=1
	local -a keys=()

	printf '{'
	printf '"dry_run":%s,' "$([[ $DRY_RUN -eq 1 ]] && printf true || printf false)"
	printf '"moved":%d,' "$MOVED_COUNT"
	printf '"moved_bytes":%d,' "$MOVED_BYTES"
	printf '"categories":{'
	if ((${#COUNT_BY_CAT[@]} > 0)); then
		keys=("${!COUNT_BY_CAT[@]}")
		while IFS= read -r cat; do
			[[ $first -eq 1 ]] || printf ','
			first=0
			printf '"%s":{"count":%d,"bytes":%d}' \
				"$(json_escape "$cat")" "${COUNT_BY_CAT[$cat]}" "${SIZE_BY_CAT[$cat]}"
		done < <(printf '%s\n' "${keys[@]}" | sort)
	fi
	printf '},'
	printf '"duplicates":{"skipped":%d,"moved":%d,"deleted":%d,"trashed":%d}' \
		"$DUP_SKIPPED" "$DUP_MOVED" "$DUP_DELETED" "$DUP_TRASHED"
	if [[ -n $LOG ]]; then
		printf ',"log":"%s"' "$(json_escape "$LOG")"
	fi
	printf '}\n'
}

print_summary() {
	local cat
	local -a keys=()

	if [[ $JSON -eq 1 ]]; then
		print_summary_json
		return 0
	fi

	if ((MOVED_COUNT == 0 && DUP_SKIPPED == 0 && DUP_DELETED == 0 && DUP_MOVED == 0 && DUP_TRASHED == 0)); then
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
		printf 'Duplicates: %d skipped, %d moved, %d deleted, %d trashed\n' \
			"$DUP_SKIPPED" "$DUP_MOVED" "$DUP_DELETED" "$DUP_TRASHED"
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

if [[ $SMART_MODE -eq 1 ]]; then
	add_managed_dir Movies
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
	if ((${#EXCLUDE_PATTERNS[@]} > 0)) && match_any_glob "$name" "${EXCLUDE_PATTERNS[@]}"; then
		return 0
	fi
	if ((${#INCLUDE_PATTERNS[@]} > 0)) && ! match_any_glob "$name" "${INCLUDE_PATTERNS[@]}"; then
		return 0
	fi
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
		# Smart mode no longer owns these names: images/documents go to XDG
		# user dirs and series live at the target root, so scan them normally.
		if [[ $SMART_MODE -eq 1 && ($cat == Images || $cat == Documents || $cat == Videos) ]]; then
			continue
		fi
		add_prune -path "$TARGET/$cat"
	done
	# Never descend into hidden directories when hidden files are excluded.
	if [[ $INCLUDE_HIDDEN -eq 0 ]]; then
		add_prune -name '.*'
	fi

	while IFS= read -r -d '' src; do
		should_skip "$src" && continue
		file_filters_skip "$src" && continue
		files+=("$src")
	done < <(find "$DIR" -mindepth 1 \( "${prune[@]}" \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null)
else
	while IFS= read -r -d '' src; do
		should_skip "$src" && continue
		file_filters_skip "$src" && continue
		files+=("$src")
	done < <(find "$DIR" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
fi

if [[ $SMART_MODE -eq 1 ]]; then
	smart_organize
elif ((${#files[@]} > 0)); then
	for src in "${files[@]}"; do
		[[ -e $src || -L $src ]] || continue
		base=$(basename -- "$src")
		ext=""
		[[ $base != .* && $base == *.* ]] && ext=${base##*.}

		structured=0
		if cat=$(rule_for "$base"); then
			:
		elif cat=$(custom_category_for "$ext"); then
			:
		else
			cat=$(category_for "$ext")
			if [[ $cat == Videos ]]; then
				# Videos are never dumped into a generic folder: recognized
				# episodes are organized, everything else stays in place.
				if [[ $TV_MODE -eq 1 ]]; then
					if tv_cat=$(tv_category "$src"); then
						cat=$tv_cat
						structured=1
					else
						printf 'left in place (unidentified video): %s\n' "$src"
						continue
					fi
				elif detect_episode "$src"; then
					cat=$(series_rel "$SMART_SHOW" "$SMART_SEASON")
					structured=1
				else
					printf 'left in place (unidentified video): %s\n' "$src"
					continue
				fi
			elif [[ $MUSIC_MODE -eq 1 && $cat == Audio ]] && music_cat=$(music_category "$src"); then
				cat=$music_cat
				structured=1
			fi
		fi

		if [[ $BY_DATE -eq 1 && $structured -eq 0 ]]; then
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

if ((UNSCHEDULE)); then
	if ! command -v crontab >/dev/null; then
		die "crontab not found"
	fi
	if crontab -l 2>/dev/null | grep -q "organize.*#organize-cron"; then
		crontab -l 2>/dev/null | grep -v "organize.*#organize-cron" | crontab -
		echo "Removed scheduled job"
	else
		echo "No scheduled job found"
	fi
	exit 0
fi

if [[ -n $SCHEDULE ]]; then
	if [[ $SCHEDULE == *"@"* ]]; then
		SCHEDULE_TIME=${SCHEDULE%%@*}
		SCHEDULE_DIR_ARG=${SCHEDULE##*@}
	else
		SCHEDULE_TIME=$SCHEDULE
		SCHEDULE_DIR_ARG=${DIR:-.}
	fi
	if [[ ! $SCHEDULE_TIME =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
		die "invalid time format, use HH:MM (e.g., 09:00)"
	fi
	SCHEDULE_HOUR=${BASH_REMATCH[1]}
	SCHEDULE_MIN=${BASH_REMATCH[2]}
	if ((SCHEDULE_HOUR < 0 || SCHEDULE_HOUR > 23 || SCHEDULE_MIN < 0 || SCHEDULE_MIN > 59)); then
		die "invalid time"
	fi
	SCHEDULE_DIR_ARG=$(eval echo "$SCHEDULE_DIR_ARG")
	[[ -d $SCHEDULE_DIR_ARG ]] || die "directory not found: $SCHEDULE_DIR_ARG"
	SCHEDULE_DIR_ARG=$(cd -- "$SCHEDULE_DIR_ARG" && pwd)
	ORG_BIN=$(command -v organize 2>/dev/null || echo "$SCRIPT_PATH")
	if ! command -v crontab >/dev/null; then
		die "crontab not found; install cron or use systemd timer"
	fi
	CRON_LINE="$SCHEDULE_MIN $SCHEDULE_HOUR * * * $ORG_BIN $SCHEDULE_DIR_ARG #organize-cron"
	(crontab -l 2>/dev/null | grep -v "organize.*#organize-cron"; echo "$CRON_LINE") | crontab -
	echo "Scheduled: $SCHEDULE_HOUR:$(printf '%02d' $SCHEDULE_MIN) daily for $SCHEDULE_DIR_ARG"
	echo "To remove: $ORG_BIN --unschedule"
	exit 0
fi

doctor_deps() {
	printf 'organize.sh %s - dependency check\n\n' "$VERSION"
	local ok=0 warn=0
	if command -v bash >/dev/null && bash --version | grep -q 'version [4-9]\|version 10'; then
		printf '  [OK] bash %s\n' "$(bash --version | head -n1 | awk '{print $4}')"
		ok=$((ok + 1))
	else
		printf '  [WARN] bash version may be too old (need >= 4)\n'
		warn=$((warn + 1))
	fi
	for cmd in find mv mkdir rm basename dirname date tr stat sort sha256sum; do
		if command -v "$cmd" >/dev/null 2>&1; then
			printf '  [OK] %s\n' "$cmd"
			ok=$((ok + 1))
		else
			printf '  [WARN] %s not found\n' "$cmd"
			warn=$((warn + 1))
		fi
	done
	if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || command -v sha256 >/dev/null 2>&1; then
		printf '  [OK] SHA256 available (for --dedupe)\n'
		ok=$((ok + 1))
	else
		printf '  [WARN] No SHA256 tool found (required for --dedupe)\n'
		warn=$((warn + 1))
	fi
	if command -v exiftool >/dev/null 2>&1; then
		printf '  [OK] exiftool (optional, for EXIF dates/music tags)\n'
		ok=$((ok + 1))
	else
		printf '  [INFO] exiftool not found (optional)\n'
	fi
	printf '\nSummary: %d ok, %d warnings/info\n' "$ok" "$warn"
	if [[ $warn -eq 0 ]]; then
		printf 'All required dependencies look good!\n'
	else
		printf 'Some optional/missing deps detected - see above.\n'
	fi
}
