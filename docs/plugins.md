# Plugins

organize.sh can load shell plugins that hook into every move.

## Loading

- Pass `--plugin FILE` (repeatable).
- Or drop `*.sh` files into `$XDG_CONFIG_HOME/organize/plugins/`
  (or `~/.config/organize/plugins/`).

Each plugin is sourced as Bash. Define these functions:

```sh
organize_pre_move() {
    # $1 = source path, $2 = destination path
    # return 0 to allow the move, non-zero to skip it
    case "$1" in *.tmp) return 1 ;; esac
    return 0
}

organize_post_move() {
    # informational; runs after a successful move
    printf 'moved: %s -> %s\n' "$1" "$2"
}
```

Plugins run only for real (non-dry-run) moves. `organize_pre_move` may
block a move by returning non-zero; the file is left in place and reported
as "skipped by plugin".
