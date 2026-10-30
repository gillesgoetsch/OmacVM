#!/usr/bin/env python3
"""Which of OmacVM's shader fixes fits this Hyprland binary (hypr-capture.sh).

    python3 -I guard.py [--installed VERSION] BINARY FOLDER...

Hyprland builds its shader files into its binary. A FOLDER (one per Hyprland
release, e.g. 0.56.2/) fits when the binary names the commit in the folder's
`original` list and carries each file listed there byte for byte. Prints the
first folder that fits and exits 0; exits 1 when none does, 2 when the binary
or a list cannot be read. Why, on stderr, completes "no OmacVM fix for ...":
it names the installed hyprland package's VERSION (pacman's, e.g. 0.58.0-1)
and the releases OmacVM has fixes for. hypr-capture.sh takes anything but 0
as "leave Hyprland's own copy".
"""
import hashlib
import os
import sys


def read_list(path):
    commit, files = None, []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            kind, _, rest = line.partition(" ")
            if kind == "commit" and rest:
                commit = rest.encode()
            elif kind == "file":
                sha, size, name, first = rest.split(" ", 3)
                files.append((sha, int(size), name, first.encode()))
            else:
                raise ValueError(f"{path}: cannot read {line!r}")
    if not commit or not files:
        raise ValueError(f"{path}: no commit or no file")
    return commit, files


def carries(data, sha, size, first):
    """The file starts at one of the places where its first line is."""
    pos = data.find(first)
    while pos >= 0:
        if hashlib.sha256(data[pos:pos + size]).hexdigest() == sha:
            return True
        pos = data.find(first, pos + 1)
    return False


def why_not(data, path, release):
    """None when the binary fits the list; else (whether it has the list's commit, why not)."""
    commit, files = read_list(path)
    if commit not in data:
        return False, f"not built from commit {commit.decode()[:8]}"
    for sha, size, name, first in files:
        if not carries(data, sha, size, first):
            return True, f"its {name} is not the one OmacVM's {release} fix is made for"
    return None


def release_of(version):
    """0.57.0 of a pacman version such as 1:0.57.0-2 (no epoch, no package release)."""
    v = version.split(":", 1)[-1]
    return v.rsplit("-", 1)[0] if "-" in v else v


def why_none(installed, reasons):
    """The end of "no OmacVM fix for ...": the installed version and what OmacVM has fixes for."""
    have = [r for r, _, _ in reasons]
    if len(have) > 1:
        fixes = f"OmacVM has fixes for {', '.join(have[:-1])} and {have[-1]}"
    else:
        fixes = f"OmacVM has a fix for {have[0]}" if have else "OmacVM has none"
    if installed:
        for release, _, why in reasons:
            if release == release_of(installed):
                return f"this build of Hyprland {installed} ({why})"
        return f"Hyprland {installed} yet ({fixes})"
    for release, same_commit, why in reasons:
        if same_commit:
            return f"this Hyprland ({why})"
    return f"this Hyprland (its version is not known; {fixes})"


def main(argv):
    args = argv[1:]
    installed = ""
    if args[:1] == ["--installed"] and len(args) > 1:
        installed, args = args[1].strip(), args[2:]
    if len(args) < 2:
        print("usage: guard.py [--installed VERSION] BINARY FOLDER...", file=sys.stderr)
        return 2
    try:
        with open(args[0], "rb") as f:
            data = f.read()
        reasons = []
        for folder in args[1:]:
            folder = folder.rstrip("/")
            release = os.path.basename(folder)
            why = why_not(data, os.path.join(folder, "original"), release)
            if why is None:
                print(release)
                return 0
            reasons.append((release, why[0], why[1]))
    except (OSError, ValueError) as e:
        print(f"this Hyprland (cannot check: {e})", file=sys.stderr)
        return 2
    print(why_none(installed, reasons), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
