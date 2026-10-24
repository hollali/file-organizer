# organize.sh

A small, dependency-light Bash script that organizes directory contents into
category folders. It supports extension-based categories, TV episode grouping,
date folders, custom rules, duplicate detection, undo, and dry runs.

## Features

- Sorts files into `Images`, `Documents`, `Videos`, `Audio`, `Archives`,
  `Disk Images`, `Code`, `Fonts`, `Executables`, and `Other`
- Optional TV mode: groups episodes as `Videos/Show/Season NN/`
- Optional music mode: groups tracks as `Audio/Artist/Album/`
- Optional date sorting: `Category/YYYY/MM/`
- Custom rules file for glob-based destinations and custom category definitions
- Duplicate detection using size and SHA-256 checksums, with skip, move,
  delete, or trash handling
- Include/exclude globs and min/max size and age filters
- Optional filename normalization (`--rename`) and symlink mode (`--link`)
- Config file for default flags, JSON summary output
- Summary report with file counts, sizes, and duplicate statistics
- Organizes in place or into a separate target directory
- Optional recursive mode and optional subfolder organizing
- Dry-run mode to preview changes
- Collision-safe: never overwrites, renames collisions as `name (1).ext`
- Undo support backed by a log file
- Skips hidden files (and hidden directories in recursive mode) by default
- No external dependencies beyond Bash and standard tools

## Requirements

- Bash 4 or newer
- `find`, `mv`, `mkdir`, `rm`, `basename`, `dirname`, `date`, `tr`, `stat`,
  `sort` (provided by GNU coreutils/findutils or BusyBox)
- `sha256sum` (or `shasum`/`sha256`) only when using `--dedupe`
- `exiftool` is optional; when present, `--by-date` uses EXIF dates for images
  and `--music` reads artist/album tags

This works on any Linux distribution that provides those tools, including
Debian/Ubuntu, Fedora/RHEL/CentOS/Rocky/Alma, Arch, openSUSE, Alpine, and
others. On a minimal Alpine install, install Bash first:

```sh
apk add bash
```

It does not use distro-specific paths, package managers, or init systems.

## Installation

Clone the repo and run it directly:

```sh
git clone https://github.com/hollali/scripts.git
cd scripts
chmod +x organize.sh
```

Optionally install it on your `PATH` using the included setup script:

```sh
./setup.sh
```

Or manually:

```sh
install -Dm755 organize.sh ~/.local/bin/organize
```

To uninstall:

```sh
./uninstall.sh
```

You can check dependencies with:

```sh
./organize.sh --doctor
```

## Usage

```sh
./organize.sh [options] [directory]
```

`directory` defaults to the current directory and is organized in place unless
`--target` is given.

### Options

| Option | Description |
| --- | --- |
| `-t, --target DIR` | Move files into `DIR` instead of organizing in place |
| `-r, --recursive` | Include files from subdirectories (flattened into categories) |
| `-F, --folders` | Also move top-level subdirectories into `Folders/` |
| `-T, --tv` | Group episode files as `Videos/Show/Season NN/` |
| `-M, --music` | Group tracks as `Audio/Artist/Album/` |
| `-H, --hidden` | Include hidden files (and hidden directories in recursive mode) |
| `-n, --dry-run` | Show what would be moved without changing anything |
| `-u, --undo` | Undo the most recent run in the given directory |
| `--by-date` | Group files as `Category/YYYY/MM/` |
| `--dedupe` | Skip files identical to ones already organized |
| `--duplicates MODE` | Duplicate handling: `skip` (default), `delete`, `move`, or `trash` |
| `--trash` | Shorthand for `--duplicates trash` |
| `-i, --include GLOB` | Only organize files whose name matches the glob (repeatable) |
| `-x, --exclude GLOB` | Skip files whose name matches the glob (repeatable) |
| `--min-size SIZE` | Skip files smaller than `SIZE` (bytes or `K`/`M`/`G` suffix) |
| `--max-size SIZE` | Skip files larger than `SIZE` (bytes or `K`/`M`/`G` suffix) |
| `--older-than DAYS` | Only organize files not modified in the last `DAYS` days |
| `--rename` | Normalize names while moving: lowercase, spaces to underscores |
| `-l, --link` | Leave a symlink at the original path pointing at the new location |
| `--rules FILE` | Load custom rules (default: `~/.config/organize/rules.conf`) |
| `--config FILE` | Load default flags from a config file |
| `--json` | Print the summary as JSON |
| `-h, --help` | Show help |

### TV episode mode

With `--tv`, video files whose names contain a season/episode marker are moved
into a per-show, per-season folder instead of the flat `Videos/` folder:

```
Videos/
  Breaking Bad/
    Season 01/
      Breaking.Bad.S01E01.mkv
      Breaking.Bad.S01E02.mkv
    Season 02/
      Breaking.Bad.S02E01.mkv
```

Recognized filename patterns include:

| Pattern | Example |
| --- | --- |
| `SxxExx` | `Show.S01E02.1080p.mkv`, `Show S1 E2.avi` |
| `NxNN` | `Show 1x02.mp4`, `Show.01x02.mkv` |
| `Season X Episode Y` | `Show Season 1 Episode 2.avi` |
| `Season X` | `Show Season 1.mkv` |
| `Sxx` | `Show.S01.mkv` |

The show name is taken from the text before the marker; dots and underscores
become spaces. Files that do not match any pattern are still placed in the
regular `Videos/` folder, and all non-video files are organized as usual.
TV matches are not given date subfolders when `--by-date` is also enabled.

### Music mode

With `--music`, audio files are grouped by artist and album when possible. If
`exiftool` is installed, the `Artist` and `Album` tags are used. Otherwise, or
as a fallback, filenames of the form `Artist - Album - NN - Title.ext` are
parsed:

```
Audio/
  Artist/
    Album/
      Artist - Album - 01 - Title.mp3
    Other Track.mp3
  loose.mp3
```

Artist and album names are sanitized into single path components (slashes are
removed, dots and underscores become spaces). Files with no recognizable
artist land in plain `Audio/`. Music matches are not given date subfolders
when `--by-date` is also enabled.

### Filtering

`--include` and `--exclude` take filename globs (matched case-insensitively
against the file name only, like rules) and may be repeated:

```sh
# Only organize images and PDFs
./organize.sh --include '*.png' --include '*.pdf' ~/Downloads

# Organize everything except archives and disk images
./organize.sh --exclude '*.zip' --exclude '*.iso' ~/Downloads
```

Files that fail an `--include` match or pass an `--exclude` match are left
in place. `--min-size` and `--max-size` accept a byte count or a `K`, `M`,
or `G` suffix, and `--older-than` takes a number of days:

```sh
# Skip junk smaller than 1 KiB and anything over 2 GiB
./organize.sh --min-size 1k --max-size 2G ~/Downloads

# Only touch files untouched for at least 30 days
./organize.sh --older-than 30 ~/Downloads
```

Size and age filters apply to files only, not to top-level folders moved with
`--folders`.

### Rename mode

`--rename` normalizes file names as they are moved: everything is lowercased,
spaces become underscores, and repeated or leading/trailing underscores are
collapsed. Extensions are lowercased too:

```
My Photo 01.PNG  ->  Images/my_photo_01.png
```

Collisions after renaming are still handled safely (`name (1).ext`). Names
that normalize to nothing keep their original form. Rename applies to files
only; folders moved with `--folders` keep their names.

### Link mode

With `--link`, files are copied into their category folders as usual, but a
symlink is left behind at the original path so nothing "disappears":

```sh
./organize.sh --link ~/Downloads
# ~/Downloads/Images/photo.png is the file; ~/Downloads/photo.png -> Images/photo.png
```

Symlinks are absolute and are recorded in the undo log; `--undo` removes the
symlink and restores the file to its original location.

### Duplicate detection

`--dedupe` compares files by size and SHA-256 checksum. It checks against files
already present in the managed destination folders and against files moved
earlier in the same run.

| `--duplicates` mode | Behavior |
| --- | --- |
| `skip` (default) | Leave the duplicate in place and report it |
| `move` | Move it to `Duplicates/` (collision-safe and undoable) |
| `delete` | Delete it permanently (not recorded in the undo log) |
| `trash` | Move it to the system trash (`$XDG_DATA_HOME/Trash`) |

`--duplicates MODE` implies `--dedupe`. `--trash` is shorthand for
`--duplicates trash`. Trash moves follow the freedesktop.org trash spec
(`files/` plus an `info/*.trashinfo` entry) and land in
`~/.local/share/Trash` when `XDG_DATA_HOME` is unset. Dry-run mode reports
what would happen without deleting, moving, or trashing anything. Use
`delete` with care.

### Date sorting

`--by-date` adds `YYYY/MM` subfolders based on the file's modification time:

```
Images/
  2024/
    03/
      photo.jpg
  2026/
    10/
      screenshot.png
```

For images, if `exiftool` is installed, the EXIF `DateTimeOriginal` (or
`CreateDate`) is used first, falling back to the file modification time.

### Custom rules

Rules are read from `--rules FILE`, or from the first existing default path:

```
$XDG_CONFIG_HOME/organize/rules.conf
~/.config/organize/rules.conf
```

Each non-comment line maps a filename glob to a relative destination folder:

```
# Custom destinations (first match wins)
invoice*.pdf   -> Documents/Invoices
*.psd          -> Images/Design
*.bak          -> Archives/Backups
```

`=>` is accepted in place of `->`. Matching is case-insensitive against the
file name only. Rules take precedence over the built-in categories and TV
mode. Destinations may be nested, but must be relative and must not contain
`..`. With `--by-date`, the date path is appended below the rule destination.
The active rules file is never moved, even when it lives inside the directory
being organized.

The same file can define custom top-level categories with `@category` lines,
mapping a category name to a list of extensions:

```
@category Comics = cbz cbr cb7
@category Books: mobi azw3
```

Files with those extensions go to `Comics/`, `Books/`, and so on instead of
the built-in category. Custom categories take precedence over the built-in
extension mapping but not over glob rules. Names must not start with `.` or
contain `/`; repeated definitions of the same name are merged.

### Categories

| Folder | Example extensions |
| --- | --- |
| `Images` | jpg, jpeg, png, gif, webp, svg, tiff, heic, raw |
| `Documents` | pdf, doc(x), txt, md, odt, rtf, xls(x), ppt(x), csv, epub |
| `Videos` | mp4, mkv, avi, mov, webm, flv, mpeg |
| `Audio` | mp3, wav, flac, aac, ogg, m4a, opus |
| `Archives` | zip, tar, gz, bz2, xz, 7z, rar, zst |
| `Disk Images` | iso, img, dmg |
| `Code` | sh, py, js, ts, json, yaml, html, css, c, cpp, go, rs, java |
| `Fonts` | ttf, otf, woff, woff2 |
| `Executables` | exe, msi, deb, rpm, AppImage, apk |
| `Other` | everything else, including files without an extension |

Extensions are matched case-insensitively.

### Summary report

Every run ends with a summary of files moved per top-level category, total size,
and duplicate counts. Dry runs are labelled as such. Example:

```
Summary:
  Documents                 2 files  1.4 MiB
  Images                    3 files  4.2 MiB
  Total                     5 files  5.6 MiB
Duplicates: 2 skipped, 1 moved, 0 deleted, 0 trashed
```

With `--json`, the summary is printed as a single JSON object instead:

```json
{"dry_run":false,"moved":5,"moved_bytes":5872025,"categories":{"Documents":{"count":2,"bytes":1468006},"Images":{"count":3,"bytes":4404019}},"duplicates":{"skipped":2,"moved":1,"deleted":0,"trashed":0},"log":"/home/user/Downloads/.organize-log-20261021-120000-1234.log"}
```

### Config file

Default flags can be stored in a config file and are prepended to the command
line (so explicit flags still win). The file is read from `--config FILE`, or
from the first existing default path:

```
$XDG_CONFIG_HOME/organize/config.conf
~/.config/organize/config.conf
```

Each line holds options, one or more per line; blank lines and `#` comments are
ignored. Only options are allowed in the config file:

```
# always organize Downloads this way
--dedupe
--duplicates trash
--exclude *.tmp
```

## Examples

Preview what would happen in `~/Downloads`:

```sh
./organize.sh --dry-run ~/Downloads
```

Organize in place:

```sh
./organize.sh ~/Downloads
```

Collect files from several levels into a separate directory:

```sh
./organize.sh -r -t ~/sorted ~/incoming
```

Also move top-level folders into `Folders/`:

```sh
./organize.sh -F ~/Downloads
```

Group TV episodes by show and season:

```sh
./organize.sh --tv ~/Downloads
```

Preview the same operation first:

```sh
./organize.sh --tv --dry-run ~/Downloads
```

Group by year and month:

```sh
./organize.sh --by-date ~/Pictures
```

Use custom rules:

```sh
./organize.sh --rules ~/.config/organize/rules.conf ~/Downloads
```

Skip duplicate files, moving them to `Duplicates/` instead:

```sh
./organize.sh --dedupe --duplicates move ~/Downloads
```

Send duplicates to the system trash instead:

```sh
./organize.sh --trash ~/Downloads
```

Group music by artist and album:

```sh
./organize.sh --music ~/Music/incoming
```

Only organize recent downloads above 1 KiB, leaving junk and old files alone:

```sh
./organize.sh --older-than 7 --min-size 1k ~/Downloads
```

Normalize names and leave symlinks behind:

```sh
./organize.sh --rename --link ~/Downloads
```

Emit a machine-readable summary:

```sh
./organize.sh --json ~/Downloads
```

## Undo

Every run that moves something writes a log in the source directory:

```
.organize-log-YYYYMMDD-HHMMSS-PID.log
```

To revert the most recent run in that directory:

```sh
./organize.sh --undo ~/Downloads
```

Undo moves files back, creates missing parent directories, removes empty
category folders, and never overwrites an existing file. If a destination is
already occupied or the file is missing, that entry is skipped with a warning.

Log files are hidden and are ignored by the organizer (even with `--hidden`).
You can delete old logs manually once you no longer need them. Files removed
with `--duplicates delete` are deleted permanently and are not in the log.
Files sent to the trash with `--duplicates trash` land in the system trash and
are not restored by `--undo`. Links left by `--link` are removed by `--undo`
before the file is moved back.

## Development

Run the test suite locally:

```sh
bash tests/test.sh
```

Continuous integration (`.github/workflows/ci.yml`) runs:

- Bash syntax checks and ShellCheck
- The full test suite on Ubuntu
- The full test suite on Alpine with only Bash installed, exercising BusyBox
  `find`, `stat`, `mv`, and related tools

Releases (`.github/workflows/release.yml`) run when a tag matching `v*` is
pushed. They build a `.tar.gz` containing `organize.sh` and `README.md`, create
a `.sha256` checksum, and publish both as GitHub release assets:

```sh
git tag v1.0.0
git push origin v1.0.0
```

There is no server component; "deployment" for this project means publishing a
release artifact through GitHub Releases.

## Notes and safety

- Run with `--dry-run` first, especially with `--recursive`.
- Symlinks are moved as files; their targets are not followed. To leave a
  symlink behind instead, use `--link`.
- `--rename` and `--link` apply to files only; `--folders` moves directories
  unchanged.
- In recursive mode, files are flattened into categories under the target
  directory; the original subdirectories are left in place (and may become
  empty).
- `--folders` only applies to top-level directories and is ignored when
  `--recursive` is used, to avoid moving directories while walking them.
- Hidden files are skipped by default. Hidden directories are not descended
  into during recursive mode unless `--hidden` is used. This protects things
  like `.git`, `.ssh`, and `.config` from being reorganized accidentally.
