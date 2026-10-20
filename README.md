# organize.sh

A small, dependency-light Bash script that organizes directory contents into
category folders. It supports extension-based categories, TV episode grouping,
date folders, custom rules, duplicate detection, undo, and dry runs.

## Features

- Sorts files into `Images`, `Documents`, `Videos`, `Audio`, `Archives`,
  `Disk Images`, `Code`, `Fonts`, `Executables`, and `Other`
- Optional TV mode: groups episodes as `Videos/Show/Season NN/`
- Optional date sorting: `Category/YYYY/MM/`
- Custom rules file for glob-based destinations
- Duplicate detection using size and SHA-256 checksums
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

This works on any Linux distribution that provides those tools, including
Debian/Ubuntu, Fedora/RHEL/CentOS/Rocky/Alma, Arch, openSUSE, Alpine, and
others. On a minimal Alpine install, install Bash first:

```sh
apk add bash
```

It does not use distro-specific paths, package managers, or init systems.

## Installation

```sh
chmod +x organize.sh
```

Optionally install it on your `PATH`:

```sh
install -Dm755 organize.sh ~/.local/bin/organize
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
| `-H, --hidden` | Include hidden files (and hidden directories in recursive mode) |
| `-n, --dry-run` | Show what would be moved without changing anything |
| `-u, --undo` | Undo the most recent run in the given directory |
| `--by-date` | Group files as `Category/YYYY/MM/` |
| `--dedupe` | Skip files identical to ones already organized |
| `--duplicates MODE` | Duplicate handling: `skip` (default), `delete`, or `move` |
| `--rules FILE` | Load custom rules (default: `~/.config/organize/rules.conf`) |
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

### Duplicate detection

`--dedupe` compares files by size and SHA-256 checksum. It checks against files
already present in the managed destination folders and against files moved
earlier in the same run.

| `--duplicates` mode | Behavior |
| --- | --- |
| `skip` (default) | Leave the duplicate in place and report it |
| `move` | Move it to `Duplicates/` (collision-safe and undoable) |
| `delete` | Delete it permanently (not recorded in the undo log) |

`--duplicates MODE` implies `--dedupe`. Dry-run mode reports what would happen
without deleting or moving anything. Use `delete` with care.

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
Duplicates: 2 skipped, 1 moved, 0 deleted
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
- Symlinks are moved as files; their targets are not followed.
- In recursive mode, files are flattened into categories under the target
  directory; the original subdirectories are left in place (and may become
  empty).
- `--folders` only applies to top-level directories and is ignored when
  `--recursive` is used, to avoid moving directories while walking them.
- Hidden files are skipped by default. Hidden directories are not descended
  into during recursive mode unless `--hidden` is used. This protects things
  like `.git`, `.ssh`, and `.config` from being reorganized accidentally.
