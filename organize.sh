#!/usr/bin/env bash
#
# organize.sh - sort files and folders into category folders.
#
# Features: extension categories, TV grouping, date sorting, custom rules,
# duplicate detection, dry-run, undo, and a summary report.
#
# Usage: ./organize.sh [options] [directory]
#

VERSION="1.3.1"

set -euo pipefail

SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")
ORIGINAL_ARGS=("$@")

acquire_lock() {
	local lockdir
	lockdir="${TMPDIR:-/tmp}/organize.lock.$(printf '%s' "$DIR" | sha256sum 2>/dev/null | awk '{print $1}' || echo $$)"
	if command -v flock >/dev/null 2>&1; then
		exec 200>"$lockdir"
		if ! flock -n 200 2>/dev/null; then
			die "another organize.sh instance is running on $DIR"
		fi
	else
		if [[ -f "$lockdir.pid" ]]; then
			local oldpid
			oldpid=$(cat "$lockdir.pid" 2>/dev/null || true)
			if [[ -n $oldpid ]] && kill -0 "$oldpid" 2>/dev/null; then
				die "another organize.sh instance is running on $DIR"
			fi
		fi
		printf '%s\n' $$ >"$lockdir.pid"
		LOCK_PID_FILE=$lockdir.pid
	fi
}

DRY_RUN=0
EXPLAIN=0
CONFIRM=0
REORGANIZE=0
USE_XDG_DIRS=0
XDG_DEST=1
WATCH_PREV_SNAP=""
WATCH=0
WATCH_INTERVAL=5
TIMER_MODE=0
UNINSTALL_TIMER=0
PLAN_FILE=""
PLAN_TEMP=""
APPLY_PLAN=""
LOCK_PID_FILE=""
RECURSIVE=0
MOVE_FOLDERS=0
INCLUDE_HIDDEN=0
UNDO=0
UNDO_INDEX=1
LIST_LOGS=0
TV_MODE=0
MUSIC_MODE=0
SMART_MODE=0
MENU=0
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
SCHEDULE_HOUR=""
SCHEDULE_MIN=""

CATEGORIES=(Images Documents Videos Audio Archives "Disk Images" Code Fonts Executables Other Folders)

RULE_PATTERNS=()
RULE_DESTS=()
RULE_CONDS=()
CAT_EXT_NAMES=()
CAT_EXT_LISTS=()
INCLUDE_PATTERNS=()
EXCLUDE_PATTERNS=()
CONFIG_ARGS=()
declare -A SIZE_INDEX=()
declare -A ALIASES=()
declare -A HASH_CACHE=()
declare -A SEEN_HASH=()
declare -A COUNT_BY_CAT=()
declare -A SIZE_BY_CAT=()
declare -A SMART_DEST=()
UNDO_LOGS=()

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
  -R, --reorganize   Re-scan existing category and show folders and re-file them
                     according to the current rules and options (undoable)
      --use-xdg-dirs Allow --smart to send images/documents to XDG user dirs
                     outside the organized folder (prints a warning otherwise)
  -F, --folders      Also move top-level subdirectories into Folders/
  -T, --tv           Group TV episodes as Videos/Show/Season NN/;
                     unrecognized videos stay in place
  -M, --music        Group tracks as Audio/Artist/Album/ (tags or "Artist - Album - N - Title")
      --menu         Interactive menu (whiptail): pick a directory, mode and
                     options, preview the plan, apply it, undo, or schedule runs
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
      --explain      Print why each file was placed where it was
      --plan FILE    Write the planned actions to FILE during a dry run
      --apply-plan FILE  Execute a reviewed plan file
      --confirm      Preview, then confirm or reject individual moves (whiptail)
  -u, --undo [N]     Undo the Nth most recent run (default: 1) in the given directory
      --undo-list    List undo history for the given directory
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
      --schedule TIMES[@DIR] Schedule daily runs at TIMES (HH:MM[,HH:MM...]) for DIR
                     (e.g. 09:00,15:00,21:00@~/Downloads)
      --unschedule   Remove scheduled cron jobs for the current directory
      --watch [SEC]  Organize repeatedly every SEC seconds (default 5)
      --install-timer TIMES[@DIR]  Install systemd user timers for DIR
      --uninstall-timer  Remove systemd timers for the current directory
  -h, --help         Show this help
EOF
}

die() {
	printf 'organize: %s\n' "$*" >&2
	exit 1
}

CRON_MARKER=""
CRON_LEGACY_DIR=""

prepare_cron_identity() {
	local dir=$1 out
	out=$(printf '%s' "$dir" | cksum) || out="0 0"
	CRON_MARKER="#organize-cron:${out%% *}"
	CRON_LEGACY_DIR=$(printf '%q' "$dir")
}

is_our_cron_line() {
	local line=$1
	[[ $line == *"$CRON_MARKER"* ]] && return 0
	[[ -n $CRON_LEGACY_DIR && $line == *" $CRON_LEGACY_DIR #organize-cron" ]] && return 0
	return 1
}

filter_our_cron_lines() {
	local line
	while IFS= read -r line; do
		is_our_cron_line "$line" || printf '%s\n' "$line"
	done
}

timer_unit_dir() {
	printf '%s/systemd/user' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

install_timer() {
	local times=$1 dir=$2 unit unit_dir line hour min
	local -a specs=()
	prepare_cron_identity "$dir"
	unit=organize-${CRON_MARKER##*:}
	unit_dir=$(timer_unit_dir)
	mkdir -p -- "$unit_dir" || die "cannot create $unit_dir"
	IFS=',' read -r -a specs <<<"$times"
	for line in "${specs[@]}"; do
		[[ $line =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || die "invalid time: $line (use HH:MM)"
		hour=$((10#${BASH_REMATCH[1]}))
		min=$((10#${BASH_REMATCH[2]}))
		((hour <= 23 && min <= 59)) || die "invalid time: $line"
	done
	{
		printf '[Unit]\nDescription=Organize files in %s\n\n[Service]\nType=oneshot\nExecStart="%s" "%s"\n' \
			"$dir" "$SCRIPT_PATH" "$dir"
	} >"$unit_dir/$unit.service"
	{
		printf '[Unit]\nDescription=Daily organization for %s\n\n[Timer]\n' "$dir"
		for line in "${specs[@]}"; do
			IFS=: read -r hour min <<<"$line"
			printf 'OnCalendar=*-*-* %02d:%02d:00\n' "$((10#$hour))" "$((10#$min))"
		done
		printf 'Persistent=true\n\n[Install]\nWantedBy=timers.target\n'
	} >"$unit_dir/$unit.timer"
	printf 'Installed %s in %s\n' "$unit" "$unit_dir"
	printf 'Enable it with: systemctl --user enable --now %s.timer\n' "$unit"
}

uninstall_timer() {
	local unit unit_dir
	prepare_cron_identity "$DIR"
	unit=organize-${CRON_MARKER##*:}
	unit_dir=$(timer_unit_dir)
	rm -f -- "$unit_dir/$unit.service" "$unit_dir/$unit.timer"
	printf 'Removed %s timer\n' "$unit"
}

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
	for cmd in find mv mkdir rm basename dirname date tr stat sort sha256sum cksum; do
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
	local file=$1 which=${2:-main} line
	local -a words=()
	[[ -f $file ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%%#*}
		read -r -a words <<<"$line"
		((${#words[@]} > 0)) || continue
		if [[ $which == dir ]]; then
			DIR_CONFIG_ARGS+=("${words[@]}")
		else
			CONFIG_ARGS+=("${words[@]}")
		fi
	done <"$file"
}

validate_config_args() {
	local w expect=0
	for w in "$@"; do
		if ((expect)); then
			expect=0
			continue
		fi
		case $w in
		--target | -t | --duplicates | --rules | --config | --include | -i | --exclude | -x | --min-size | --max-size | --older-than | --plan | --apply-plan)
			expect=1
			;;
		-*) ;;
		*) die "config: only options are allowed: $w" ;;
		esac
	done
}

prescan_dir_arg() {
	local -a args=("$@")
	local i=0 arg
	while ((i < ${#args[@]})); do
		arg=${args[i]}
		case $arg in
		--target | -t | --duplicates | --rules | --config | --include | -i | --exclude | -x | --min-size | --max-size | --older-than | --plan | --apply-plan | --install-timer | --schedule)
			i=$((i + 2))
			;;
		--watch | --undo)
			if ((i + 1 < ${#args[@]})) && [[ ${args[i + 1]} =~ ^[0-9]+$ ]]; then
				i=$((i + 2))
			else
				i=$((i + 1))
			fi
			;;
		-*)
			i=$((i + 1))
			;;
		*)
			printf '%s' "$arg"
			return 0
			;;
		esac
	done
	return 1
}

CONFIG_CLI=""
DIR_CONFIG_ARGS=()
DIR_PRESCAN=$(prescan_dir_arg "$@") || DIR_PRESCAN=.
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
		((${#CONFIG_ARGS[@]} == 0)) || validate_config_args "${CONFIG_ARGS[@]}"
	elif [[ -n $CONFIG_CLI ]]; then
		die "config file not found: $CONFIG_CLI"
	fi

	# Per-directory defaults live next to the files and override the global
	# config, while explicit command-line flags still win over both.
	if [[ -f $DIR_PRESCAN/.organize.conf ]]; then
		load_default_config "$DIR_PRESCAN/.organize.conf" dir
		((${#DIR_CONFIG_ARGS[@]} == 0)) || validate_config_args "${DIR_CONFIG_ARGS[@]}"
	fi

	local_config_args=()
	((${#CONFIG_ARGS[@]} == 0)) || local_config_args+=("${CONFIG_ARGS[@]}")
	((${#DIR_CONFIG_ARGS[@]} == 0)) || local_config_args+=("${DIR_CONFIG_ARGS[@]}")
	if ((${#local_config_args[@]} > 0)); then
		set -- "${local_config_args[@]}" "$@"
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
	-R | --reorganize)
		REORGANIZE=1
		RECURSIVE=1
		shift
		;;
	--use-xdg-dirs)
		USE_XDG_DIRS=1
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
	--menu | --gui | --interactive)
		MENU=1
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
	--explain)
		EXPLAIN=1
		shift
		;;
	--plan)
		(($# >= 2)) || die "option $1 requires an argument"
		PLAN_FILE=$2
		shift 2
		;;
	--apply-plan)
		(($# >= 2)) || die "option $1 requires an argument"
		APPLY_PLAN=$2
		shift 2
		;;
	--confirm)
		CONFIRM=1
		shift
		;;
	--watch)
		WATCH=1
		if (($# >= 2)) && [[ $2 =~ ^[0-9]+$ ]]; then
			WATCH_INTERVAL=$2
			shift 2
		else
			shift
		fi
		;;
	--install-timer)
		(($# >= 2)) || die "option $1 requires an argument"
		SCHEDULE=$2
		TIMER_MODE=1
		shift 2
		;;
	--uninstall-timer)
		UNINSTALL_TIMER=1
		shift
		;;
	-u | --undo)
		UNDO=1
		if (($# >= 2)) && [[ $2 =~ ^[0-9]+$ ]]; then
			UNDO_INDEX=$2
			shift 2
		else
			shift
		fi
		;;
	--undo-list | --list-logs)
		LIST_LOGS=1
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
		doctor_deps
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

if ((WATCH && (CONFIRM || MENU))); then
	die "--watch cannot be combined with --confirm or --menu"
fi

[[ -z $DIR ]] && DIR=.
[[ -d $DIR ]] || die "not a directory: $DIR"
DIR=$(cd -- "$DIR" && pwd)
TARGET=${TARGET:-$DIR}
[[ -d $TARGET ]] || mkdir -p -- "$TARGET"
TARGET=$(cd -- "$TARGET" && pwd)

if ((SMART_MODE)); then
	if ((USE_XDG_DIRS == 0)) && [[ $TARGET != "$DIR" ]]; then
		XDG_DEST=0
	elif ((USE_XDG_DIRS == 0)); then
		printf 'organize: warning: --smart sends images and documents to XDG user dirs outside %s (~/Pictures, ~/Documents). Pass --use-xdg-dirs to confirm, or --target to keep them inside the target.\n' "$DIR" >&2
	fi
fi

if ((UNINSTALL_TIMER)); then
	uninstall_timer
	exit 0
fi

if ((UNSCHEDULE)); then
	if ! command -v crontab >/dev/null; then
		die "crontab not found"
	fi
	prepare_cron_identity "$DIR"
	CRONTAB_EXISTING=$(crontab -l 2>/dev/null || true)
	CRONTAB_REMAINING=$(printf '%s\n' "$CRONTAB_EXISTING" | filter_our_cron_lines)
	if [[ $CRONTAB_REMAINING != "$CRONTAB_EXISTING" ]]; then
		printf '%s\n' "$CRONTAB_REMAINING" | crontab -
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
		SCHEDULE_DIR_ARG=$DIR
	fi
	# shellcheck disable=SC2088 # match a literal leading tilde
	case "$SCHEDULE_DIR_ARG" in
	"~") SCHEDULE_DIR_ARG=$HOME ;;
	"~/"*) SCHEDULE_DIR_ARG=$HOME/${SCHEDULE_DIR_ARG:2} ;;
	esac
	[[ -d $SCHEDULE_DIR_ARG ]] || die "directory not found: $SCHEDULE_DIR_ARG"
	SCHEDULE_DIR_ARG=$(cd -- "$SCHEDULE_DIR_ARG" && pwd)
	prepare_cron_identity "$SCHEDULE_DIR_ARG"
	ORG_BIN=$(command -v organize 2>/dev/null || echo "$SCRIPT_PATH")
	if ! command -v crontab >/dev/null; then
		die "crontab not found; install cron or use systemd timer"
	fi
	IFS=',' read -r -a SCHEDULE_TIMES <<<"$SCHEDULE_TIME"
	CRON_LINES=()
	SCHEDULE_LABELS=()
	for schedule_time in "${SCHEDULE_TIMES[@]}"; do
		if [[ ! $schedule_time =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
			die "invalid time format: $schedule_time (use HH:MM, comma-separated)"
		fi
		SCHEDULE_HOUR=$((10#${BASH_REMATCH[1]}))
		SCHEDULE_MIN=$((10#${BASH_REMATCH[2]}))
		if ((SCHEDULE_HOUR > 23 || SCHEDULE_MIN > 59)); then
			die "invalid time: $schedule_time"
		fi
		CRON_LINES+=("$(printf '%d %d * * * %s %s %s' "$SCHEDULE_MIN" "$SCHEDULE_HOUR" "$(printf '%q' "$ORG_BIN")" "$(printf '%q' "$SCHEDULE_DIR_ARG")" "$CRON_MARKER")")
		SCHEDULE_LABELS+=("$(printf '%02d:%02d' "$SCHEDULE_HOUR" "$SCHEDULE_MIN")")
	done
	if ((TIMER_MODE)); then
		install_timer "$SCHEDULE_TIME" "$SCHEDULE_DIR_ARG"
		exit 0
	fi
	CRONTAB_EXISTING=$(crontab -l 2>/dev/null | filter_our_cron_lines || true)
	{
		if [[ -n $CRONTAB_EXISTING ]]; then
			printf '%s\n' "$CRONTAB_EXISTING"
		fi
		printf '%s\n' "${CRON_LINES[@]}"
	} | crontab -
	SCHEDULE_LABEL_LIST=""
	for schedule_label in "${SCHEDULE_LABELS[@]}"; do
		[[ -n $SCHEDULE_LABEL_LIST ]] && SCHEDULE_LABEL_LIST+=", "
		SCHEDULE_LABEL_LIST+=$schedule_label
	done
	echo "Scheduled: $SCHEDULE_LABEL_LIST daily for $SCHEDULE_DIR_ARG"
	echo "To remove: cd $(printf '%q' "$SCHEDULE_DIR_ARG") && $(printf '%q' "$ORG_BIN") --unschedule"
	exit 0
fi

trap on_exit EXIT
acquire_lock

LOG=""
MOVES_STARTED=0
ROLLBACK_ACTIVE=0
RESTORE_SKIPPED=0
MOVE_REASON=""
READ_LOG_TARGET=$DIR
READ_LOG_SRCS=()
READ_LOG_DESTS=()

ensure_log() {
	[[ $DRY_RUN -eq 1 ]] && return 1
	[[ -n $LOG ]] && return 0
	LOG=$DIR/.organize-log-$(date +%Y%m%d-%H%M%S)-$$.log
	printf '#organize-v2\0%s\0' "$TARGET" >"$LOG"
	return 0
}

log_move() {
	ensure_log || return
	printf '%s\0%s\0' "$1" "$2" >>"$LOG"
}

record_plan() {
	[[ -n $PLAN_FILE ]] || return 0
	printf '%s\0%s\0%s\0' "$1" "$2" "$3" >>"$PLAN_FILE"
}

apply_plan_file() {
	local file=$1 type src dest final size skipped=0
	[[ -f $file ]] || die "plan file not found: $file"
	while IFS= read -r -d '' type && IFS= read -r -d '' src && IFS= read -r -d '' dest; do
		if [[ ! -e $src && ! -L $src ]]; then
			printf 'skip (missing): %s\n' "$src" >&2
			skipped=$((skipped + 1))
			continue
		fi
		case $type in
		M)
			mkdir -p -- "$(dirname -- "$dest")" || return 1
			final=$(unique_path "$dest" 0)
			size=$(file_size "$src" 2>/dev/null || printf 0)
			log_move "$src" "$final"
			MOVES_STARTED=1
			mv -- "$src" "$final" || return 1
			printf 'moved: %s -> %s\n' "$src" "$final"
			record_move Plan "$size"
			;;
		D)
			stage_deleted "$src" || return 1
			DUP_DELETED=$((DUP_DELETED + 1))
			printf 'deleted: %s\n' "$src"
			;;
		T)
			trash_file "$src" || return 1
			DUP_TRASHED=$((DUP_TRASHED + 1))
			printf 'trashed: %s\n' "$src"
			;;
		*)
			printf 'unknown plan action: %s\n' "$type" >&2
			skipped=$((skipped + 1))
			;;
		esac
	done <"$file"
	((skipped == 0)) || printf 'plan: %d action(s) skipped\n' "$skipped" >&2
}

confirm_and_apply_plan() {
	local plan=$1 type src dest i=0 out tmp approved tag
	local -a items=() selected=()
	if [[ ${CI:-} == true ]]; then
		printf 'CI detected: applying all planned moves without confirmation.\n' >&2
		DRY_RUN=0
		PLAN_FILE=""
		apply_plan_file "$plan"
		return 0
	fi
	[[ -t 0 ]] || die "--confirm requires an interactive terminal"
	command -v whiptail >/dev/null 2>&1 || die "whiptail is required for --confirm"
	while IFS= read -r -d '' type && IFS= read -r -d '' src && IFS= read -r -d '' dest; do
		i=$((i + 1))
		items+=("$i" "$(printf '%q -> %q' "$src" "$dest")" on)
	done <"$plan"
	((i > 0)) || {
		printf 'Nothing to organize.\n'
		return 0
	}
	tmp=$(mktemp "${TMPDIR:-/tmp}/organize-confirm-XXXXXX") || return 1
	if ! whiptail --title "Confirm changes" --checklist \
		"Select the moves to apply:" "$(ui_rows)" "$(ui_cols)" 0 "${items[@]}" 2>"$tmp"; then
		printf 'No changes applied.\n'
		rm -f -- "$tmp"
		return 0
	fi
	read -r -a selected <"$tmp"
	approved=$(mktemp "${TMPDIR:-/tmp}/organize-approved-XXXXXX") || {
		rm -f -- "$tmp"
		return 1
	}
	i=0
	while IFS= read -r -d '' type && IFS= read -r -d '' src && IFS= read -r -d '' dest; do
		i=$((i + 1))
		for tag in "${selected[@]}"; do
			if [[ $tag == "$i" ]]; then
				printf '%s\0%s\0%s\0' "$type" "$src" "$dest" >>"$approved"
				break
			fi
		done
	done <"$plan"
	rm -f -- "$tmp"
	DRY_RUN=0
	PLAN_FILE=""
	apply_plan_file "$approved"
	rm -f -- "$approved"
}

watch_snapshot() {
	local f line ext
	while IFS= read -r -d '' f; do
		ext=${f##*.}
		ext=${ext,,}
		case $ext in
		part | crdownload | tmp | partial | download | '!ut') continue ;;
		esac
		line=$(stat -c '%n %s %Y' "$f" 2>/dev/null || stat -f '%n %z %m' "$f" 2>/dev/null || true)
		[[ -n $line ]] && printf '%s\n' "$line"
	done < <(find "$DIR" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null) | LC_ALL=C sort
}

watch_files_stable() {
	local snap
	snap=$(watch_snapshot)
	if [[ -n $snap && $snap == "$WATCH_PREV_SNAP" ]]; then
		WATCH_PREV_SNAP=""
		return 0
	fi
	WATCH_PREV_SNAP=$snap
	return 1
}

watch_loop() {
	local -a args=()
	local use_inotify=0
	local arg skip=0 i
	if [[ -n $LOCK_PID_FILE ]]; then
		rm -f -- "$LOCK_PID_FILE"
		LOCK_PID_FILE=""
	fi
	exec 200>&- 2>/dev/null || true
	for ((i = 0; i < ${#ORIGINAL_ARGS[@]}; i++)); do
		arg=${ORIGINAL_ARGS[i]}
		if [[ $arg == --watch ]]; then
			skip=1
			continue
		fi
		if ((skip)) && [[ $arg =~ ^[0-9]+$ ]]; then
			skip=0
			continue
		fi
		skip=0
		args+=("$arg")
	done
	command -v inotifywait >/dev/null 2>&1 && use_inotify=1
	local mode=polling
	((use_inotify)) && mode=inotify
	printf 'Watching %s every %ss with stable-file detection (%s, Ctrl-C to stop)\n' \
		"$DIR" "$WATCH_INTERVAL" "$mode"
	trap 'printf "\nStopping watch.\n"; exit 0' INT TERM
	while :; do
		if ((use_inotify)); then
			inotifywait -q -e close_write,moved_to -t "$WATCH_INTERVAL" "$DIR" >/dev/null 2>&1 || true
		else
			sleep "$WATCH_INTERVAL"
		fi
		if watch_files_stable; then
			bash "$SCRIPT_PATH" "${args[@]}" \
				--exclude '*.part' --exclude '*.crdownload' --exclude '*.tmp' \
				--exclude '*.partial' --exclude '*.download' --exclude '*.!ut' \
				>/dev/null 2>&1 || true
		fi
	done
}

read_log_entries() {
	local log=$1 rec src dest i
	local -a records=()
	READ_LOG_TARGET=$DIR
	READ_LOG_SRCS=()
	READ_LOG_DESTS=()
	while IFS= read -r -d '' rec; do
		records+=("$rec")
	done <"$log"
	if [[ ${records[0]:-} == '#organize-v2' ]]; then
		READ_LOG_TARGET=${records[1]:-$DIR}
		for ((i = 2; i + 1 < ${#records[@]}; i += 2)); do
			READ_LOG_SRCS+=("${records[i]}")
			READ_LOG_DESTS+=("${records[i + 1]}")
		done
		return 0
	fi
	while IFS=$'\t' read -r src dest || [[ -n $src ]]; do
		if [[ $src == '#target' ]]; then
			READ_LOG_TARGET=$dest
			continue
		fi
		READ_LOG_SRCS+=("$src")
		READ_LOG_DESTS+=("$dest")
	done <"$log"
}

purge_stale_delete_backups() {
	local d name latest=""
	local -a logs=()
	[[ $DRY_RUN -eq 1 ]] && return 0
	[[ -d $TARGET/.organize-deleted ]] || return 0
	shopt -s nullglob
	logs=("$DIR"/.organize-log-*.log)
	for d in "${logs[@]}"; do
		[[ -z $latest || $d -nt $latest ]] && latest=$d
	done
	[[ -n $latest ]] || latest="none"
	for d in "$TARGET"/.organize-deleted/.organize-log-*; do
		name=$(basename -- "$d")
		[[ $DIR/$name.log == "$latest" ]] && continue
		rm -rf -- "$d"
	done
	shopt -u nullglob
	rmdir -- "$TARGET/.organize-deleted" 2>/dev/null || true
}

is_hidden_name() {
	[[ $1 == .* && $1 != . && $1 != .. ]]
}

restore_entries() {
	local log_target=$1 src dest i
	RESTORE_SKIPPED=0
	for ((i = ${#READ_LOG_SRCS[@]} - 1; i >= 0; i--)); do
		src=${READ_LOG_SRCS[i]}
		dest=${READ_LOG_DESTS[i]}
		if [[ ! -e $dest ]]; then
			printf 'skip (missing): %s\n' "$dest" >&2
			remove_empty_parents "$dest" "$log_target"
			continue
		fi
		mkdir -p -- "$(dirname -- "$src")"
		if [[ -L $src && $src -ef $dest ]]; then
			rm -f -- "$src"
		elif [[ -e $src ]]; then
			printf 'skip (target exists): %s\n' "$src" >&2
			RESTORE_SKIPPED=$((RESTORE_SKIPPED + 1))
			continue
		fi
		if ! mv -- "$dest" "$src"; then
			printf 'skip (move failed): %s\n' "$dest" >&2
			RESTORE_SKIPPED=$((RESTORE_SKIPPED + 1))
			continue
		fi
		if [[ $dest == */Trash/files/* ]]; then
			rm -f -- "${dest%/files/*}/info/$(basename -- "$dest").trashinfo"
		fi
		remove_empty_parents "$dest" "$log_target"
		printf 'restored: %s\n' "$src"
	done
}

undo_logs_newest_first() {
	local log latest
	local -a logs=() remaining=() next=()
	UNDO_LOGS=()

	shopt -s nullglob
	logs=("$DIR"/.organize-log-*.log)
	shopt -u nullglob
	((${#logs[@]} > 0)) || return 1

	remaining=("${logs[@]}")
	while ((${#remaining[@]} > 0)); do
		latest=${remaining[0]}
		for log in "${remaining[@]}"; do
			[[ $log -nt $latest ]] && latest=$log
		done
		UNDO_LOGS+=("$latest")
		next=()
		for log in "${remaining[@]}"; do
			[[ $log == "$latest" ]] || next+=("$log")
		done
		remaining=()
		((${#next[@]} > 0)) && remaining=("${next[@]}")
	done
	return 0
}

log_stamp_label() {
	local base=$1 stamp date_part time_part
	base=${base##*/}
	stamp=${base#.organize-log-}
	stamp=${stamp%-*}
	date_part=${stamp%%-*}
	time_part=${stamp#*-}
	if [[ $date_part =~ ^[0-9]{8}$ && $time_part =~ ^[0-9]{6}$ ]]; then
		printf '%s-%s-%s %s:%s:%s' \
			"${date_part:0:4}" "${date_part:4:2}" "${date_part:6:2}" \
			"${time_part:0:2}" "${time_part:2:2}" "${time_part:4:2}"
	else
		printf '%s' "$base"
	fi
}

list_undo_logs() {
	local log i=0
	undo_logs_newest_first || {
		printf 'No organize logs in %s.\n' "$DIR"
		return 0
	}
	for log in "${UNDO_LOGS[@]}"; do
		i=$((i + 1))
		read_log_entries "$log"
		printf '%d  %s  %d move(s)  %s\n' \
			"$i" "$(log_stamp_label "$log")" "${#READ_LOG_SRCS[@]}" "$READ_LOG_TARGET"
	done
}

undo_run() {
	local index=$1 log
	[[ $index =~ ^[0-9]+$ ]] || die "invalid undo index: $index"
	((index >= 1)) || die "undo index must be 1 or greater"

	undo_logs_newest_first || die "no organize log found in $DIR"
	((${#UNDO_LOGS[@]} >= index)) ||
		die "only ${#UNDO_LOGS[@]} organize log(s) in $DIR"
	log=${UNDO_LOGS[index - 1]}

	read_log_entries "$log"
	if ((${#READ_LOG_SRCS[@]} == 0)); then
		rm -f -- "$log"
		printf 'Nothing to undo.\n'
		return
	fi

	restore_entries "$READ_LOG_TARGET"
	rm -f -- "$log"
	printf 'Undo complete.\n'
}

on_exit() {
	local status=$?
	trap - EXIT
	[[ -n $LOCK_PID_FILE ]] && rm -f -- "$LOCK_PID_FILE" 2>/dev/null || true
	[[ -n $PLAN_TEMP ]] && rm -f -- "$PLAN_TEMP" 2>/dev/null || true
	if ((status != 0 && MOVES_STARTED == 1 && ROLLBACK_ACTIVE == 0 && DRY_RUN == 0)); then
		ROLLBACK_ACTIVE=1
		printf 'organize: error detected - rolling back this run...\n' >&2
		if [[ -n $LOG && -f $LOG ]]; then
			read_log_entries "$LOG"
			restore_entries "$READ_LOG_TARGET"
			if ((RESTORE_SKIPPED == 0)); then
				rm -f -- "$LOG"
				printf 'organize: rollback complete.\n' >&2
			else
				printf 'organize: rollback incomplete; run --undo to finish.\n' >&2
			fi
		fi
	fi
	exit "$status"
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

	show=$(smart_show_name "$show")
	[[ -n $show ]] || return 1

	series_rel "$show" "$((10#$season))" /Videos
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
media_user_dir() {
	local key=$1 fallback=$2
	if ((XDG_DEST)); then
		xdg_user_dir "$key" "$fallback"
	else
		printf '%s/%s\n' "$TARGET" "$fallback"
	fi
}

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

fold_diacritics() {
	local s=$1 i
	local -a from=(á à â ä ã å ç é è ê ë í ì î ï ñ ó ò ô ö õ ú ù û ü ý ÿ æ œ ø ß Á À Â Ä Ã Å Ç É È Ê Ë Í Ì Î Ï Ñ Ó Ò Ô Ö Õ Ú Ù Û Ü Ý Ÿ Æ Œ Ø)
	local -a to=(a a a a a a c e e e e i i i i n o o o o o u u u u y y ae oe o ss a a a a a a c e e e e i i i i n o o o o o u u u u y y ae oe o)
	for ((i = 0; i < ${#from[@]}; i++)); do
		s=${s//"${from[i]}"/"${to[i]}"}
	done
	printf '%s' "$s"
}

# Canonical comparison key for a media name: case, accents, separators and
# punctuation are ignored so "Breaking.Bad", "breaking_bad" and "Breaking-Bad"
# all resolve to the same folder.
name_key() {
	local s
	s=$(fold_diacritics "${1,,}")
	s=${s//&/ and }
	s=${s//[^[:alnum:] ]/ }
	while [[ $s == *"  "* ]]; do
		s=${s//  / }
	done
	s=${s#"${s%%[! ]*}"}
	s=${s%"${s##*[! ]}"}
	printf '%s' "$s"
}

apply_alias() {
	local name=$1 key
	key=$(name_key "$name")
	[[ -n $key && -n ${ALIASES[$key]:-} ]] && printf '%s' "${ALIASES[$key]}" || printf '%s' "$name"
}

# Find an existing child directory of PARENT whose name matches WANT by its
# normalized key, so a library never gains a second folder for the same series
# just because of case, punctuation or accents. Prints the resolved absolute
# path (whether or not it exists yet).
resolve_child_dir() {
	local parent=$1 want=$2 d base want_key base_key
	[[ -d $parent ]] || {
		printf '%s/%s\n' "$parent" "$want"
		return
	}
	want_key=$(name_key "$want")
	shopt -s nullglob
	for d in "$parent"/*/; do
		base=${d%/}
		base=${base##*/}
		base_key=$(name_key "$base")
		if [[ -n $want_key && $base_key == "$want_key" ]]; then
			shopt -u nullglob
			printf '%s\n' "${d%/}"
			return
		fi
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
	apply_alias "$s"
}

# Return the season number when NAME is a season folder such as
# "Season 1", "Season 01", "S01", or "Series 2".
season_from_folder() {
	local name=$1
	local re_season='^[Ss]eason[._ -]*([0-9]{1,2})$'
	local re_series='^[Ss]eries[._ -]*([0-9]{1,2})$'
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
		local pre rest inner post
		pre=${name%%\[*}
		rest=${name#*\[}
		inner=${rest%%\]*}
		post=${rest#*\]}
		if [[ $inner =~ $re_year ]]; then
			year=$inner
		fi
		name="$pre $post"
	done
	while [[ $name == *'('*')'* ]]; do
		local pre rest inner post
		pre=${name%%\(*}
		rest=${name#*\(}
		inner=${rest%%\)*}
		post=${rest#*\)}
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

	SMART_TITLE=$(apply_alias "$out")
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
			nl | dut | dutch | pl | pol | polish | tr | tur | turkish | hin | hindi | \
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
	local show=$1 season=$2 root=${3:-} cur
	cur=$(resolve_child_dir "$TARGET$root" "$show")
	cur=$(resolve_season_dir "$cur" "$season")
	printf '%s\n' "${cur#"$TARGET"/}"
}

dir_has_video() {
	local d=$1 f ext
	while IFS= read -r -d '' f; do
		ext=${f##*.}
		ext=${ext,,}
		[[ $(category_for "$ext") == Videos ]] && return 0
	done < <(find "$d" -maxdepth 3 -type f -print0 2>/dev/null)
	return 1
}

# Consolidate sibling folders that belong to the same series but were created
# with different spelling, case or punctuation. Every move is logged so it can
# be reverted with --undo.
merge_variant_dirs() {
	local parent=$1 d base key canonical variant f rel sub s target_dir cat skip
	local -A seen=()
	[[ -d $parent ]] || return 0
	shopt -s nullglob
	for d in "$parent"/*/; do
		d=${d%/}
		base=${d##*/}
		is_hidden_name "$base" && continue
		[[ $base == .organize-deleted ]] && continue
		skip=0
		for cat in "${CATEGORIES[@]}" Movies Duplicates; do
			[[ $base == "$cat" ]] && skip=1
		done
		((skip)) && continue
		dir_has_video "$d" || continue
		key=$(name_key "$base")
		[[ -n $key ]] || continue
		if [[ -z ${seen[$key]:-} ]]; then
			seen[$key]=$d
			continue
		fi
		canonical=${seen[$key]}
		variant=$d
		[[ $canonical == "$variant" ]] && continue
		while IFS= read -r -d '' f; do
			should_skip "$f" && continue
			rel=${f#"$variant"/}
			sub=${rel%/*}
			[[ $sub == "$rel" ]] && sub=""
			target_dir=$canonical
			if [[ -n $sub ]]; then
				if [[ $sub != */* ]] && s=$(season_from_folder "$sub"); then
					target_dir=$(resolve_season_dir "$canonical" "$s")
				else
					target_dir=$canonical/$sub
				fi
			fi
			move_one "$f" "$target_dir" 0 Merge
		done < <(find "$variant" -mindepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
		if [[ $DRY_RUN -eq 0 ]]; then
			while IFS= read -r -d '' f; do
				rmdir -- "$f" 2>/dev/null || true
			done < <(find "$variant" -depth -type d -print0 2>/dev/null)
		fi
		seen[$key]=$canonical
	done
	shopt -u nullglob
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
		if ((REORGANIZE == 0)); then
			for cat in "${CATEGORIES[@]}"; do
				if [[ $SMART_MODE -eq 1 && ($cat == Images || $cat == Documents || $cat == Videos) ]]; then
					continue
				fi
				[[ $top == "$cat" ]] && skip=1
			done
		fi
		((skip == 1)) && continue
		[[ $TARGET != "$DIR" && ($d == "$TARGET" || $d == "$TARGET"/*) ]] && continue
		rmdir -- "$d" 2>/dev/null || true
	done < <(find "$DIR" -mindepth 1 -depth -type d -not -name '.*' -print0 2>/dev/null)
}

# Smart media organizer. Recursively inspects every file, groups episodes by
# show/season, movies by title/year, and other media by type, then moves
# related sidecar files (subtitles, nfo, artwork) with their video.
smart_organize() {
	local src base ext rel key cat date_dir name d abs_dir label dest_dir ctx akey
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
		if rule_for "$src" >/dev/null; then
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
		akey="$d/$key"
		[[ -n $key ]] && assoc["$akey"]=$rel
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
		MOVE_REASON=""
		if cat=$(rule_for "$src"); then
			rel=$cat
			label=${cat%%/*}
			MOVE_REASON="custom rule"
		elif [[ -n ${SMART_DEST[$src]:-} ]]; then
			rel=${SMART_DEST[$src]}
			label=Videos
			[[ $rel == Movies/* ]] && label=Movies
			MOVE_REASON="detected $label: $rel"
		else
			key=$(assoc_key "$base")
			akey="$d/$key"
			if [[ -n $key && -n ${assoc["$akey"]:-} ]]; then
				rel=${assoc["$akey"]}
				label=Videos
				[[ $rel == Movies/* ]] && label=Movies
				MOVE_REASON="sidecar matched to $rel"
			elif is_sidecar_file "$src" && [[ -n ${dir_dest[$d]:-} ]]; then
				if [[ -n ${dir_ambig[$d]:-} ]]; then
					printf 'left in place (ambiguous sidecar): %s\n' "$src"
					continue
				fi
				rel=${dir_dest[$d]}
				label=Videos
				[[ $rel == Movies/* ]] && label=Movies
				MOVE_REASON="sidecar for video in this folder"
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
					abs_dir=$(media_user_dir PICTURES Pictures)
					ctx=$(context_for "$src") || ctx=""
					[[ -n $ctx ]] && abs_dir=$abs_dir/$(sanitize_component "$ctx")
					[[ -n $date_dir ]] && abs_dir=$abs_dir/$date_dir
					label=Images
					MOVE_REASON="image detected; filed under Pictures"
					;;
				Documents)
					abs_dir=$(media_user_dir DOCUMENTS Documents)
					ctx=$(context_for "$src") || ctx=""
					[[ -n $ctx ]] && abs_dir=$abs_dir/$(sanitize_component "$ctx")
					abs_dir=$abs_dir/$(document_type_dir "$ext")
					label=Documents
					MOVE_REASON="document detected; filed under Documents"
					;;
				Audio)
					if music_cat=$(music_category "$src"); then
						rel=$music_cat
					else
						rel=Audio
					fi
					label=Audio
					MOVE_REASON="audio detected; filed under $rel"
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
	local natural=$dest_dir/$name
	if [[ $natural == "$src" ]] || [[ -e $natural && $src -ef $natural ]]; then
		printf 'already organized: %s\n' "$src"
		MOVE_REASON=""
		return 0
	fi
	dest=$(unique_path "$natural" "$is_dir")
	LAST_DEST=$dest

	if [[ $EXPLAIN -eq 1 && $JSON -eq 0 ]]; then
		if [[ -n $MOVE_REASON ]]; then
			printf 'why: %s -> %s (%s)\n' "$src" "$dest" "$MOVE_REASON"
		else
			printf 'why: %s -> %s (category %s)\n' "$src" "$dest" "${label:-$cat}"
		fi
	fi
	MOVE_REASON=""

	if [[ $is_dir -eq 0 ]]; then
		size=$(file_size "$src" 2>/dev/null || printf 0)
	fi

	if [[ $DRY_RUN -eq 1 ]]; then
		if [[ $LINK -eq 1 ]]; then
			printf 'would move: %s -> %s (symlink left)\n' "$src" "$dest"
		else
			printf 'would move: %s -> %s\n' "$src" "$dest"
		fi
		record_plan M "$src" "$dest"
		record_move "${label:-$cat}" "$size"
		return
	fi

	mkdir -p -- "$dest_dir"
	log_move "$src" "$dest"
	MOVES_STARTED=1
	mv -- "$src" "$dest"
	if [[ $LINK -eq 1 ]]; then
		ln -s -- "$dest" "$src"
		printf 'moved: %s -> %s (symlink left)\n' "$src" "$dest"
	else
		printf 'moved: %s -> %s\n' "$src" "$dest"
	fi
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
	local file=$1 line pattern dest cond tok lineno=0
	local cat_name cat_exts
	local -a ext_arr=()
	[[ -f $file ]] || die "rules file not found: $file"

	while IFS= read -r line || [[ -n $line ]]; do
		lineno=$((lineno + 1))
		line=$(trim "$line")
		[[ -z $line || $line == \#* ]] && continue

		if [[ $line == @alias* ]]; then
			line=${line#@alias}
			line=$(trim "$line")
			if [[ $line == *'->'* ]]; then
				pattern=${line%%->*}
				dest=${line#*->}
			elif [[ $line == *'=>'* ]]; then
				pattern=${line%%=>*}
				dest=${line#*=>}
			else
				die "rules: $file:$lineno: expected '@alias NAME -> CANONICAL'"
			fi
			pattern=$(trim "$pattern")
			dest=$(trim "$dest")
			[[ -n $pattern && -n $dest ]] || die "rules: $file:$lineno: empty alias"
			[[ $dest == */* ]] && die "rules: $file:$lineno: canonical name must not contain '/'"
			ALIASES["$(name_key "$pattern")"]=$dest
			continue
		fi

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

		cond=""
		if [[ $pattern =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\][[:space:]]*$ ]]; then
			pattern=${BASH_REMATCH[1]}
			cond=${BASH_REMATCH[2]}
		fi
		pattern=$(trim "$pattern")
		dest=$(trim "$dest")
		cond=$(trim "$cond")
		[[ -n $pattern ]] || die "rules: $file:$lineno: empty pattern"
		[[ -n $dest ]] || die "rules: $file:$lineno: empty folder"
		if [[ -n $cond ]]; then
			for tok in ${cond//,/ }; do
				if [[ ! $tok =~ ^(size|age)(>=|<=|>|<)([0-9]+[kKmMgG]?)$ ]]; then
					die "rules: $file:$lineno: invalid condition '$tok' (use size/age with >, >=, <, <=)"
				fi
				if [[ ${BASH_REMATCH[1]} == age && ${BASH_REMATCH[3]} == *[kKmMgG]* ]]; then
					die "rules: $file:$lineno: age must be a whole number of days"
				fi
			done
		fi
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
		RULE_CONDS+=("$cond")
		if [[ ${dest%%/*} != *'{'* ]]; then
			add_managed_dir "${dest%%/*}"
		fi
	done <"$file"
}

file_year_month() {
	local src=$1 stamp
	stamp=$(stat -c %y "$src" 2>/dev/null || true)
	if [[ $stamp =~ ^([0-9]{4})-([0-9]{2}) ]]; then
		printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		return 0
	fi
	stamp=$(date -r "$src" '+%Y %m' 2>/dev/null || true)
	[[ -n $stamp ]] && {
		printf '%s\n' "$stamp"
		return 0
	}
	return 1
}

compare_number() {
	local op=$1 a=$2 b=$3
	case $op in
	'>') ((a > b)) ;;
	'>=') ((a >= b)) ;;
	'<') ((a < b)) ;;
	'<=') ((a <= b)) ;;
	*) return 1 ;;
	esac
}

rule_conditions_met() {
	local conds=$1 src=$2 field op val size="" mtime="" now age tok
	local -a toks=()
	conds=${conds//,/ }
	# shellcheck disable=SC2206 # word splitting is intentional
	toks=($conds)
	((${#toks[@]} > 0)) || return 0

	for tok in "${toks[@]}"; do
		if [[ $tok =~ ^(size|age)(>=|<=|>|<)(.+)$ ]]; then
			field=${BASH_REMATCH[1]}
			op=${BASH_REMATCH[2]}
			val=${BASH_REMATCH[3]}
		else
			return 1
		fi
		if [[ $field == size ]]; then
			[[ -n $size ]] || size=$(file_size "$src" 2>/dev/null || printf '0')
			[[ $size =~ ^[0-9]+$ ]] || return 1
			val=$(parse_size "$val") || return 1
			compare_number "$op" "$size" "$val" || return 1
		else
			if [[ -z $mtime ]]; then
				mtime=$(stat -c %Y "$src" 2>/dev/null || date -r "$src" +%s 2>/dev/null || true)
			fi
			[[ $mtime =~ ^[0-9]+$ ]] || return 1
			[[ $val =~ ^[0-9]+$ ]] || return 1
			now=$(date +%s)
			age=$(((now - mtime) / 86400))
			compare_number "$op" "$age" "$val" || return 1
		fi
	done
	return 0
}

expand_rule_dest() {
	local dest=$1 src=$2 ext=$3 ym="" y="" m=""
	if [[ $dest == *'{year}'* || $dest == *'{month}'* ]]; then
		ym=$(file_year_month "$src" 2>/dev/null || true)
		if [[ -n $ym ]]; then
			y=${ym%% *}
			m=${ym##* }
		fi
	fi
	dest=${dest//\{year\}/$y}
	dest=${dest//\{month\}/$m}
	dest=${dest//\{ext\}/$ext}
	while [[ $dest == *//* ]]; do
		dest=${dest//\/\//\/}
	done
	while [[ $dest == */ ]]; do
		dest=${dest%/}
	done
	dest=${dest#./}
	printf '%s\n' "$dest"
}

rule_for() {
	local src=$1 base ext i
	base=$(basename -- "$src")
	ext=""
	[[ $base != .* && $base == *.* ]] && ext=${base##*.}
	ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
	((${#RULE_PATTERNS[@]} > 0)) || return 1

	shopt -s nocasematch
	for ((i = 0; i < ${#RULE_PATTERNS[@]}; i++)); do
		# shellcheck disable=SC2053 # the right-hand side is intentionally a glob
		if [[ $base == ${RULE_PATTERNS[i]} ]]; then
			if [[ -n ${RULE_CONDS[i]} ]] && ! rule_conditions_met "${RULE_CONDS[i]}" "$src"; then
				continue
			fi
			expand_rule_dest "${RULE_DESTS[i]}" "$src" "$ext"
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

stage_deleted() {
	local src=$1 stage_dir stage_file base n=0
	ensure_log || return 1
	stage_dir=$TARGET/.organize-deleted/$(basename -- "$LOG" .log)
	mkdir -p -- "$stage_dir" || return 1
	base=$(basename -- "$src")
	stage_file=$stage_dir/$base
	while [[ -e $stage_file ]]; do
		n=$((n + 1))
		stage_file=$stage_dir/$base.$n
	done
	log_move "$src" "$stage_file"
	MOVES_STARTED=1
	mv -- "$src" "$stage_file" || return 1
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
	log_move "$src" "$dest"
	MOVES_STARTED=1
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
			record_plan D "$src" ""
		else
			stage_deleted "$src" || die "cannot stage duplicate for deletion: $src"
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
			record_plan T "$src" ""
		else
			trash_file "$src"
			printf 'trashed duplicate: %s (matches %s)\n' "$src" "$match"
		fi
		;;
	esac
}

record_move() {
	local cat=${1%%/*} size=$2 count bytes
	count=${COUNT_BY_CAT["$cat"]:-0}
	COUNT_BY_CAT["$cat"]=$((count + 1))
	bytes=${SIZE_BY_CAT["$cat"]:-0}
	SIZE_BY_CAT["$cat"]=$((bytes + size))
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

# ---------------- interactive menu (--menu, whiptail) ----------------

ui_cols() {
	tput cols 2>/dev/null || printf 80
}
ui_rows() {
	tput lines 2>/dev/null || printf 24
}
ui_size() {
	local w h
	w=$(ui_cols)
	h=$(ui_rows)
	((w > 100)) && w=100
	((w < 46)) && w=46
	((h > 26)) && h=26
	((h < 8)) && h=8
	UIW=$w
	UIH=$h
}

menu_msg() {
	ui_size
	whiptail --title "organize.sh ${VERSION}" --msgbox "$1" "$UIH" "$UIW" || true
}

# Run organize.sh with ARGS in a fresh, non-interactive pass and show the
# captured output in a scrollable text box. Output is always shown, even when
# the run fails, so errors are visible inside the menu.
menu_run() {
	local file
	file=$(mktemp "${TMPDIR:-/tmp}/organize-menu-XXXXXX")
	bash "$SCRIPT_PATH" "$@" >"$file" 2>&1 || true
	ui_size
	whiptail --title "organize.sh ${VERSION}" --textbox "$file" "$UIH" "$UIW" || true
	rm -f -- "$file"
	return 0
}

menu_pick_directory() {
	local dir=$1 out
	while :; do
		if ! out=$(whiptail --title "Directory" --inputbox \
			"Directory to organize:" 10 "$UIW" "$dir" 3>&1 1>&2 2>&3); then
			return 1
		fi
		dir=$(trim "${out//\"/}")
		if [[ -z $dir ]]; then
			dir=$PWD
		elif [[ -d $dir ]]; then
			dir=$(cd -- "$dir" && pwd)
			printf '%s\n' "$dir"
			return 0
		fi
		menu_msg "Not a directory: $dir"
	done
}

menu_main() {
	local dir=$1 choice mode pref out dup preview args opt
	ui_size
	while :; do
		if ! choice=$(whiptail --title "organize.sh ${VERSION} - interactive menu" --menu \
			"Working directory: $dir" "$UIH" "$UIW" 0 \
			dir "Change directory" \
			organize "Organize files (sort, media, music...)" \
			undo "Undo the last organize in this directory" \
			doctor "Dependency check" \
			schedule "Schedule a daily run for this directory" \
			unschedule "Remove the scheduled run" \
			quit "Exit" 3>&1 1>&2 2>&3); then
			return 0
		fi
		choice=${choice//\"/}
		case $choice in
		quit)
			return 0
			;;
		dir)
			if out=$(menu_pick_directory "$dir"); then
				dir=$out
			fi
			;;
		undo)
			menu_run -u "$dir"
			;;
		doctor)
			menu_run --doctor
			;;
		schedule)
			if out=$(whiptail --title "Daily schedule" --inputbox \
				"Run organize.sh daily at (HH:MM) for:" 10 "$UIW" "09:00" 3>&1 1>&2 2>&3); then
				menu_run --schedule "${out//\"/}@$dir"
			fi
			;;
		unschedule)
			menu_run --unschedule
			;;
		organize)
			if ! out=$(whiptail --title "Mode" --radiolist \
				"How should files be organized?" "$UIH" "$UIW" 0 \
				smart "Smart media mode: series/seasons, movies, XDG Pictures/Docs..." "ON" \
				tv "TV episodes only: Videos/Show/Season NN" "OFF" \
				music "Music mode: Audio/Artist/Album" "OFF" \
				classic "Sort by file type only (Images/, Documents/...)" "OFF" \
				3>&1 1>&2 2>&3); then
				continue
			fi
			mode=${out//\"/}

			if ! pref=$(whiptail --title "Options" --checklist \
				"Toggle extra options (space to select, enter to confirm)" \
				"$UIH" "$UIW" 0 \
				dry-run "Preview first, then confirm" "ON" \
				recursive "Include subdirectories" "OFF" \
				folders "Also move top-level folders" "OFF" \
				hidden "Include hidden files" "OFF" \
				by-date "Group into Category/YYYY/MM" "OFF" \
				rename "Normalize filenames while moving" "OFF" \
				dedupe "Detect duplicate files" "OFF" \
				3>&1 1>&2 2>&3); then
				continue
			fi
			pref=${pref//\"/}

			dup="none"
			if [[ $pref == *dedupe* ]]; then
				if ! out=$(whiptail --title "Duplicates" --radiolist \
					"How should duplicate files be handled?" "$UIH" "$UIW" 0 \
					skip "Keep the first copy, skip the rest" "ON" \
					move "Move duplicates to Duplicates/" "OFF" \
					delete "Delete duplicates" "OFF" \
					trash "Trash duplicates (recoverable)" "OFF" \
					3>&1 1>&2 2>&3); then
					continue
				fi
				dup=${out//\"/}
			fi

			preview=0
			[[ $pref == *dry-run* ]] && preview=1

			args=()
			case $mode in
			smart) args+=(--smart) ;;
			tv) args+=(--tv) ;;
			music) args+=(--music) ;;
			esac
			for opt in recursive folders hidden by-date rename; do
				if [[ $pref == *"$opt"* ]]; then
					case $opt in
					recursive) args+=(-r) ;;
					folders) args+=(-F) ;;
					hidden) args+=(-H) ;;
					by-date) args+=(--by-date) ;;
					rename) args+=(--rename) ;;
					esac
				fi
			done
			case $dup in
			skip) args+=(--duplicates skip) ;;
			delete) args+=(--duplicates delete) ;;
			move) args+=(--duplicates move) ;;
			trash) args+=(--duplicates trash) ;;
			esac

			if ((preview)); then
				menu_run "${args[@]}" -n "$dir"
				if whiptail --title "Apply changes?" --yesno \
					"Apply these changes for real (no dry run)?" "$UIH" "$UIW"; then
					menu_run "${args[@]}" "$dir"
				fi
			else
				menu_run "${args[@]}" "$dir"
			fi
			;;
		esac
		# Refresh the displayed directory after organizer runs.
		dir=$(cd -- "$dir" && pwd)
	done
}

if ((WATCH)); then
	watch_loop
	exit 0
fi

if [[ -n $APPLY_PLAN ]]; then
	apply_plan_file "$APPLY_PLAN"
	print_summary
	exit 0
fi

if [[ $CONFIRM -eq 1 ]]; then
	if [[ ${CI:-} != true ]]; then
		[[ -t 0 ]] || die "--confirm requires an interactive terminal"
		command -v whiptail >/dev/null 2>&1 || die "whiptail is required for --confirm"
	fi
	DRY_RUN=1
	PLAN_TEMP=$(mktemp "${TMPDIR:-/tmp}/organize-plan-XXXXXX") || die "cannot create plan file"
	: >"$PLAN_TEMP"
	PLAN_FILE=$PLAN_TEMP
elif [[ -n $PLAN_FILE ]]; then
	: >"$PLAN_FILE" || die "cannot write plan file: $PLAN_FILE"
fi

if [[ $LIST_LOGS -eq 1 ]]; then
	acquire_lock
	list_undo_logs
	exit 0
fi

if [[ $UNDO -eq 1 ]]; then
	acquire_lock
	undo_run "$UNDO_INDEX"
	exit 0
fi

if [[ $MENU -eq 1 ]]; then
	[[ -t 0 ]] || die "--menu requires an interactive terminal (tty)"
	command -v whiptail >/dev/null 2>&1 ||
		die "whiptail is required for --menu (install it with your package manager)"
	acquire_lock
	menu_main "$DIR"
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
	[[ $name == .organize.conf ]] && return 0
	[[ $src == "$TARGET"/.organize-deleted/* ]] && return 0
	[[ $INCLUDE_HIDDEN -eq 0 ]] && is_hidden_name "$name" && return 0
	if ((${#EXCLUDE_PATTERNS[@]} > 0)) && match_any_glob "$name" "${EXCLUDE_PATTERNS[@]}"; then
		return 0
	fi
	if ((${#INCLUDE_PATTERNS[@]} > 0)) && ! match_any_glob "$name" "${INCLUDE_PATTERNS[@]}"; then
		return 0
	fi
	return 1
}

preflight_space() {
	local total=0 f dev_src dev_dst avail size
	[[ $DRY_RUN -eq 1 ]] && return 0
	dev_src=$(stat -c %d "$DIR" 2>/dev/null || stat -f %d "$DIR" 2>/dev/null || true)
	dev_dst=$(stat -c %d "$TARGET" 2>/dev/null || stat -f %d "$TARGET" 2>/dev/null || true)
	[[ -n $dev_src && -n $dev_dst && $dev_src == "$dev_dst" ]] && return 0
	for f in "${files[@]}"; do
		[[ -e $f ]] || continue
		size=$(file_size "$f" 2>/dev/null || printf 0)
		total=$((total + size))
	done
	((total == 0)) && return 0
	avail=$(df -Pk "$TARGET" 2>/dev/null | awk 'NR == 2 { print $4 }') || return 0
	[[ $avail =~ ^[0-9]+$ ]] || return 0
	if ((total / 1024 + 1024 > avail)); then
		die "not enough free space on $TARGET: need about $((total / 1048576)) MiB, have $((avail / 1024)) MiB"
	fi
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
		# Reorganize and smart modes need to look inside the folders they own.
		if [[ $REORGANIZE -eq 1 ]] ||
			[[ $SMART_MODE -eq 1 && ($cat == Images || $cat == Documents || $cat == Videos) ]]; then
			continue
		fi
		add_prune -path "$TARGET/$cat"
	done
	add_prune -path "$TARGET/.organize-deleted"
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

preflight_space

if [[ $SMART_MODE -eq 1 ]]; then
	smart_organize
elif ((${#files[@]} > 0)); then
	for src in "${files[@]}"; do
		[[ -e $src || -L $src ]] || continue
		base=$(basename -- "$src")
		ext=""
		[[ $base != .* && $base == *.* ]] && ext=${base##*.}

		structured=0
		MOVE_REASON=""
		if cat=$(rule_for "$src"); then
			MOVE_REASON="custom rule"
		elif cat=$(custom_category_for "$ext"); then
			MOVE_REASON="custom category $cat"
		else
			cat=$(category_for "$ext")
			MOVE_REASON="extension .${ext:-none}"
			if [[ $cat == Videos ]]; then
				# Videos are never dumped into a generic folder: recognized
				# episodes are organized, everything else stays in place.
				if [[ $TV_MODE -eq 1 ]]; then
					if tv_cat=$(tv_category "$src"); then
						cat=$tv_cat
						MOVE_REASON="TV episode"
						structured=1
					else
						printf 'left in place (unidentified video): %s\n' "$src"
						continue
					fi
				elif detect_episode "$src"; then
					cat=$(series_rel "$SMART_SHOW" "$SMART_SEASON")
					MOVE_REASON="TV episode: $SMART_SHOW season $SMART_SEASON"
					structured=1
				else
					printf 'left in place (unidentified video): %s\n' "$src"
					continue
				fi
			elif [[ $MUSIC_MODE -eq 1 && $cat == Audio ]] && music_cat=$(music_category "$src"); then
				cat=$music_cat
				MOVE_REASON="music tags: $music_cat"
				structured=1
			fi
		fi

		if [[ $BY_DATE -eq 1 && $structured -eq 0 ]]; then
			date_dir=$(date_path "$src" "$cat" 2>/dev/null || true)
			if [[ -n $date_dir ]]; then
				cat=$cat/$date_dir
				MOVE_REASON+="; date $date_dir"
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

if [[ $TV_MODE -eq 1 ]]; then
	merge_variant_dirs "$TARGET/Videos"
else
	merge_variant_dirs "$TARGET"
fi

if ((REORGANIZE)); then
	prune_empty_source_dirs
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
purge_stale_delete_backups

if [[ $CONFIRM -eq 1 && -n $PLAN_TEMP ]]; then
	confirm_and_apply_plan "$PLAN_TEMP"
fi
