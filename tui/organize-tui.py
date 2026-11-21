#!/usr/bin/env python3
"""A small curses TUI wrapper around organize.sh.

Requires Python 3 with the standard-library curses module (Linux/macOS).
It never reimplements organizing logic; every action shells out to organize.sh.
"""
import curses
import os
import shlex
import subprocess
import sys

SCRIPT = os.environ.get("ORGANIZE_SCRIPT", "organize.sh")


def find_script():
    if os.path.isabs(SCRIPT) and os.path.exists(SCRIPT):
        return SCRIPT
    for cand in (SCRIPT, os.path.join(os.path.dirname(__file__), "..", "organize.sh")):
        p = os.path.abspath(cand)
        if os.path.exists(p):
            return p
    # fall back to PATH
    return "organize.sh"


def run_organize(script, directory, opts, dry=True):
    cmd = [script] + opts + (["-n"] if dry else []) + [directory]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        return out.returncode, (out.stdout + out.stderr)
    except subprocess.TimeoutExpired:
        return 1, "timed out\n"
    except FileNotFoundError as e:
        return 1, str(e) + "\n"


def main(stdscr):
    curses.curs_set(0)
    stdscr.keypad(True)
    script = find_script()
    directory = os.getcwd()
    options = []  # list of (flag, label, state)
    opts_state = {
        "-r": False, "--tv": False, "--smart": False, "-M": False,
        "--hidden": False, "--by-date": False, "--rename": False,
        "-l": False, "--dedupe": False,
    }
    order = ["-r", "--tv", "--smart", "-M", "--hidden", "--by-date", "--rename", "-l", "--dedupe"]
    labels = {
        "-r": "recursive", "--tv": "tv mode", "--smart": "smart media",
        "-M": "music", "--hidden": "hidden", "--by-date": "by date",
        "--rename": "rename", "-l": "link", "--dedupe": "dedupe",
    }
    output = ["Press 'p' to preview, 'a' to apply, 'q' to quit."]
    scroll = 0
    status = ""

    def build_opts():
        return [f for f in order if opts_state[f]]

    def refresh_preview():
        nonlocal output, scroll, status
        status = "running dry run..."
        stdscr.refresh()
        rc, text = run_organize(script, directory, build_opts(), dry=True)
        output = text.splitlines() or ["(no output)"]
        scroll = 0
        status = "dry run rc=%d" % rc

    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        # header
        stdscr.addstr(0, 0, "organize TUI  script=%s" % script, curses.A_BOLD)
        stdscr.addstr(1, 0, "directory: %s" % directory)
        stdscr.addstr(2, 0, "options: " + "  ".join(
            ("[%s] %s" % ("x" if opts_state[f] else " ", labels[f])) for f in order))
        stdscr.addstr(3, 0, "keys: p preview  a apply  d edit dir  o toggle (1-9)  u undo  q quit")
        stdscr.addstr(4, 0, status)
        # output pane
        pane_top = 6
        pane_h = h - pane_top - 1
        for i in range(pane_h):
            idx = scroll + i
            if idx < len(output):
                line = output[idx]
                if len(line) > w - 1:
                    line = line[:w - 1]
                try:
                    stdscr.addstr(pane_top + i, 0, line)
                except curses.error:
                    pass
        stdscr.refresh()

        ch = stdscr.getch()
        if ch in (ord("q"), 27):
            break
        elif ch == ord("p"):
            refresh_preview()
        elif ch == ord("a"):
            status = "applying..."
            stdscr.refresh()
            rc, text = run_organize(script, directory, build_opts(), dry=False)
            output = text.splitlines() or ["(no output)"]
            scroll = 0
            status = "apply rc=%d" % rc
        elif ch == ord("d"):
            curses.echo()
            stdscr.addstr(h - 1, 0, "new directory: ")
            stdscr.refresh()
            s = stdscr.getstr(h - 1, 16, 200)
            curses.noecho()
            try:
                nd = s.decode().strip()
            except Exception:
                nd = ""
            if nd and os.path.isdir(nd):
                directory = os.path.abspath(nd)
                status = "directory changed"
            else:
                status = "not a directory: %s" % nd
        elif ch == ord("u"):
            status = "undoing..."
            stdscr.refresh()
            rc, text = run_organize(script + " -u", directory, [], dry=False) if False else (1, "")
            # undo via direct call
            try:
                out = subprocess.run([script, "-u", directory], capture_output=True, text=True, timeout=300)
                rc, text = out.returncode, (out.stdout + out.stderr)
            except Exception as e:
                rc, text = 1, str(e)
            output = text.splitlines() or ["(no output)"]
            scroll = 0
            status = "undo rc=%d" % rc
        elif ch == curses.KEY_UP:
            scroll = max(0, scroll - 1)
        elif ch == curses.KEY_DOWN:
            scroll = min(max(0, len(output) - 1), scroll + 1)
        elif ch == curses.KEY_PPAGE:
            scroll = max(0, scroll - (h - pane_top - 1))
        elif ch == curses.KEY_NPAGE:
            scroll = min(max(0, len(output) - 1), scroll + (h - pane_top - 1))
        elif ord("1") <= ch <= ord("9"):
            idx = ch - ord("1")
            if idx < len(order):
                f = order[idx]
                opts_state[f] = not opts_state[f]
                status = "%s %s" % (labels[f], "on" if opts_state[f] else "off")


if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
PY