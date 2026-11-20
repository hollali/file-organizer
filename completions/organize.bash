# bash completion for organize.sh
_organize() {
	local cur prev opts
	COMPREPLY=()
	cur=${COMP_WORDS[COMP_CWORD]}
	prev=${COMP_WORDS[COMP_CWORD - 1]}
	opts="-t --target -r --recursive -R --reorganize --use-xdg-dirs -F --folders
		-T --tv -M --music --smart --media --menu --gui --interactive -H --hidden
		-n --dry-run --explain --plan --apply-plan --confirm --watch
		--install-timer --uninstall-timer -u --undo --undo-list --list-logs
		-i --include -x --exclude --min-size --max-size --older-than --rename
		-l --link --json --version --doctor --schedule --unschedule
		--install-deps --trash --by-date --dedupe --duplicates --rules --config
		-h --help"

	case $prev in
	-t | --target | --plan | --apply-plan | --install-timer | --schedule | --rules | --config)
		mapfile -t COMPREPLY < <(compgen -f -- "$cur")
		return
		;;
	-i | --include | -x | --exclude)
		mapfile -t COMPREPLY < <(compgen -W '*.tmp *.part *.crdownload' -- "$cur")
		return
		;;
	--duplicates)
		mapfile -t COMPREPLY < <(compgen -W 'skip delete move trash' -- "$cur")
		return
		;;
	--older-than | --watch | --undo)
		mapfile -t COMPREPLY < <(compgen -W '1 7 30 60' -- "$cur")
		return
		;;
	--min-size | --max-size)
		mapfile -t COMPREPLY < <(compgen -W '1M 10M 100M 1G' -- "$cur")
		return
		;;
	esac

	if [[ $cur == -* ]]; then
		mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
		return
	fi
	mapfile -t COMPREPLY < <(compgen -d -- "$cur")
}

complete -o bashdefault -o default -F _organize organize
complete -o bashdefault -o default -F _organize organize.sh
