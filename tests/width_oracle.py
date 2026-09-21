#!/usr/bin/env python3
"""Independent display-width oracle for statusline output.

Deliberately does NOT mirror statusline.sh's approach (codepoint count plus a
hand-maintained list of wide chars). This walks every character and asks
unicodedata for its East Asian Width class, so a wide char the shell script
forgot to list still gets counted here.
"""
import re
import sys
import unicodedata

ANSI = re.compile(r"\x1b\[[0-9;]*m")
OSC8 = re.compile(r"\x1b\]8;[^\x07\x1b]*(?:\x07|\x1b\\)")


def display_width(s: str) -> int:
    s = OSC8.sub("", ANSI.sub("", s))
    w = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def main() -> int:
    budget = int(sys.argv[1])
    # Above this width the progressive-degradation ladder is expected to find a
    # fitting variant on its own. Falling back to clamp_line there means a rung
    # of the ladder is broken: clamp_line strips colour and hard-truncates, so
    # the line still "fits" and a width-only assertion stays green.
    ladder_expected = budget >= 35
    quiet = "-q" in sys.argv
    failures = 0
    for i, line in enumerate(sys.stdin.read().split("\n"), 1):
        if not line:
            continue
        w = display_width(line)
        clamped = line.rstrip().endswith("…")
        problems = []
        if w > budget:
            problems.append("OVER")
        if clamped and ladder_expected:
            problems.append("CLAMPED")
        if problems:
            failures += 1
            print(f"  L{i} {'+'.join(problems):<12} width={w:3d} budget={budget}")
        elif not quiet:
            print(f"  L{i} ok           width={w:3d} budget={budget}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
