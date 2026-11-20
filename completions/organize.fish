complete -c organize -f
complete -c organize.sh -f

for cmd in organize organize.sh
    complete -c $cmd -s t -l target -d 'Move files into DIR' -r -F
    complete -c $cmd -s r -l recursive -d 'Include files from subdirectories'
    complete -c $cmd -s R -l reorganize -d 'Rescan files already inside category folders'
    complete -c $cmd -l use-xdg-dirs -d 'Allow smart mode to use XDG user dirs'
    complete -c $cmd -s F -l folders -d 'Move top-level folders into Folders/'
    complete -c $cmd -s T -l tv -d 'Group episodes as Videos/Show/Season NN/'
    complete -c $cmd -s M -l music -d 'Group tracks as Audio/Artist/Album/'
    complete -c $cmd -l smart -d 'Smart media mode'
    complete -c $cmd -l media -d 'Smart media mode'
    complete -c $cmd -l menu -d 'Interactive menu'
    complete -c $cmd -l gui -d 'Interactive menu'
    complete -c $cmd -l interactive -d 'Interactive menu'
    complete -c $cmd -s H -l hidden -d 'Include hidden files'
    complete -c $cmd -s n -l dry-run -d 'Preview without changing anything'
    complete -c $cmd -l explain -d 'Print a reason for every move'
    complete -c $cmd -l plan -d 'Write planned actions to FILE' -r -F
    complete -c $cmd -l apply-plan -d 'Apply a reviewed plan file' -r -F
    complete -c $cmd -l confirm -d 'Select individual moves interactively'
    complete -c $cmd -l watch -d 'Organize repeatedly every SEC seconds' -x -a '1 5 10 30 60'
    complete -c $cmd -l install-timer -d 'Install systemd user timers' -x
    complete -c $cmd -l uninstall-timer -d 'Remove systemd timers'
    complete -c $cmd -s u -l undo -d 'Undo the Nth most recent run' -x -a '1 2 3 4 5'
    complete -c $cmd -l undo-list -d 'List undo history'
    complete -c $cmd -l list-logs -d 'List undo history'
    complete -c $cmd -s i -l include -d 'Only organize matching files' -r
    complete -c $cmd -s x -l exclude -d 'Skip matching files' -r
    complete -c $cmd -l min-size -d 'Skip files smaller than SIZE' -x -a '1M 10M 100M 1G'
    complete -c $cmd -l max-size -d 'Skip files larger than SIZE' -x -a '1M 10M 100M 1G'
    complete -c $cmd -l older-than -d 'Only organize files older than DAYS' -x -a '1 7 30 60'
    complete -c $cmd -l rename -d 'Normalize names while moving'
    complete -c $cmd -s l -l link -d 'Leave a symlink at the original path'
    complete -c $cmd -l json -d 'Print the summary as JSON'
    complete -c $cmd -l version -d 'Show the version and exit'
    complete -c $cmd -l doctor -d 'Check dependencies'
    complete -c $cmd -l schedule -d 'Install daily cron jobs' -x
    complete -c $cmd -l unschedule -d 'Remove cron jobs'
    complete -c $cmd -l install-deps -d 'Install missing dependencies'
    complete -c $cmd -l trash -d 'Move duplicates to the trash'
    complete -c $cmd -l by-date -d 'Group files as Category/YYYY/MM/'
    complete -c $cmd -l dedupe -d 'Skip files identical to organized ones'
    complete -c $cmd -l duplicates -d 'Duplicate handling' -x -a 'skip delete move trash'
    complete -c $cmd -l rules -d 'Load custom rules' -r -F
    complete -c $cmd -l config -d 'Load default flags' -r -F
    complete -c $cmd -s h -l help -d 'Show help'
end
