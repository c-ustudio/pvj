#!/usr/bin/env python3
"""summarize.py <runs dir> [label ...] — session.sh output as one markdown table.

One row per runs/<label>/s<n>: am start TotalTime, [boot] storage ready and
splash-gone (ms since engine start), boot-window frames over 50 ms, the [perf]
windows' frames over 33 ms, files/ and cache/ KB + file counts, thumbnails,
shader-cache files. Add context (clip count, what changed) by hand.
"""
import pathlib
import re
import sys


def grab(pattern, text, default="?"):
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else default


def main() -> None:
    runs = pathlib.Path(sys.argv[1])
    labels = sys.argv[2:] or sorted(p.name for p in runs.iterdir() if p.is_dir())
    print("| build | s | am start ms | storage ready | interactive | boot >50 ms "
          "| perf >33 ms per 30 s | files KB / n | cache KB / n | thumbs | shader |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for label in labels:
        d = runs / label
        nums = sorted(int(p.stem[1:].split(".")[0]) for p in d.glob("s*.log"))
        for n in nums:
            log = (d / f"s{n}.log").read_text(errors="ignore")
            start = (d / f"s{n}.start").read_text(errors="ignore") if (d / f"s{n}.start").exists() else ""
            du = (d / f"s{n}.du").read_text(errors="ignore") if (d / f"s{n}.du").exists() else ""
            perf = " / ".join(re.findall(r"\[perf\] 30 s: [\d.]+ fps, (\d+) frames", log)) or "?"
            print(f"| {label} | {n} | {grab(r'TotalTime: (\d+)', start)} "
                  f"| {grab(r'\[boot\] (\d+) ms storage ready', log)} "
                  f"| {grab(r'\[boot\] (\d+) ms splash gone', log)} "
                  f"| {grab(r'first 20 s: \d+ frames, (\d+) over', log)} | {perf} "
                  f"| {grab(r'^(\d+)\s+files$', du)} / {grab(r'files_n (\d+)', du)} "
                  f"| {grab(r'^(\d+)\s+cache$', du)} / {grab(r'cache_n (\d+)', du)} "
                  f"| {grab(r'thumbs_n (\d+)', du)} | {grab(r'shader_n (\d+)', du)} |")


if __name__ == "__main__":
    main()
