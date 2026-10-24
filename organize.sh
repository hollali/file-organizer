#!/usr/bin/env bash
#
# organize.sh - sort files and folders into category folders.
#
# Features: extension categories, TV grouping, date sorting, custom rules,
# duplicate detection, dry-run, undo, and a summary report.
#
# Usage: ./organize.sh [options] [directory]
#

VERSION="1.0.0"

set -euo pipefail

SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")

DRY_RUN=0
RECURSIVE=0
MOVE_FOLDERS=0
INCLUDE_HIDDEN=0
UNDO=0
TV_MODE=0
MUSIC_MODE=0
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

usage() {
	cat <<EOF
Usage: organize.sh [options] [directory] (v${VERSION})

Sort files in DIRECTORY (default: .) into category folders.

Options:
  -t, --target DIR   Move files into DIR instead of organizing in place
  -r, --recursive    Include files in subdirectories (moved to DIRECTORY/category)
  -F, --folders      Also move top-level subdirectories into Folders/
  -T, --tv           Group TV episodes as Videos/Show/Season NN/
  -M, --music        Group tracks as Audio/Artist/Album/ (tags or "Artist - Album - N - Title")
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

move_one() {
	local src=$1 cat=$2 is_dir=${3:-0}
	local dest_dir=$TARGET/$cat
	local dest size=0 name
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

if ((${#files[@]} > 0)); then
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
			if [[ $TV_MODE -eq 1 && $cat == Videos ]] && tv_cat=$(tv_category "$src"); then
				cat=$tv_cat
				structured=1
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
