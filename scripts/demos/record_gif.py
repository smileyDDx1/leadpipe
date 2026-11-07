#!/usr/bin/env python3
"""Turns the live output of a demo script into an animated GIF.

    scripts/demos/autoscaling.sh 2>&1 | python scripts/demos/record_gif.py
        --command scripts/demos/autoscaling.sh --out docs/demos/autoscaling

It writes <out>.gif and <out>.txt, and passes the output through so the run can be watched. Nothing
is staged or edited: every line is what the script printed, at the moment it printed it. Long waits
are shortened so a 7 minute run fits in under a minute, and each frame shows the real time elapsed.

Needs Pillow, which is only used here, so it is not a dependency of the services.
"""

import argparse
import re
import sys
import textwrap
import time
from pathlib import Path

from PIL import Image, ImageColor, ImageDraw, ImageFont

COLUMNS = 112
ROWS = 32
FONT_SIZE = 14
LINE_HEIGHT = 18
PADDING = 12
BAR_HEIGHT = 26

# Output lines arriving closer together than this share one frame.
BATCH_SECONDS = 0.15
MIN_FRAME_MS = 300
MAX_FRAME_MS = 2000
LAST_FRAME_MS = 10000

BACKGROUND = "#0d1117"
BAR = "#21262d"
MUTED = "#8b949e"
TEXT = "#e6edf3"
HEADING = "#58a6ff"
GOOD = "#3fb950"
BAD = "#ff7b72"

FONT_PATHS = (
    "C:/Windows/Fonts/CascadiaMono.ttf",
    "C:/Windows/Fonts/consola.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
)

HEADING_LINE = re.compile(r"^\[\d\d:\d\d:\d\d\]")
GOOD_LINE = re.compile(r"\b(PASS|pass|replaced by|backlog cleared)\b")
BAD_LINE = re.compile(r"\b(FAIL|FAILED|fail|CrashLoopBackOff|BLOCKED|Error)\b|\bfailed:")


def colour_of(line: str) -> str:
    if HEADING_LINE.match(line):
        return HEADING
    if BAD_LINE.search(line):
        return BAD
    if GOOD_LINE.search(line):
        return GOOD
    return TEXT


def load_font() -> ImageFont.FreeTypeFont:
    for path in FONT_PATHS:
        if Path(path).exists():
            return ImageFont.truetype(path, FONT_SIZE)
    raise SystemExit(f"No monospace font found. Looked for: {', '.join(FONT_PATHS)}")


def capture(stream) -> list[tuple[float, str]]:
    """Reads the demo's output until it ends, and returns (seconds since start, line) pairs."""
    started = time.monotonic()
    captured = []
    for raw in stream:
        line = raw.rstrip("\r\n").expandtabs(8)
        print(line, flush=True)
        captured.append((time.monotonic() - started, line))
    captured.append((time.monotonic() - started, ""))
    return captured


def batches(captured: list[tuple[float, str]]) -> list[tuple[float, list[str]]]:
    grouped: list[tuple[float, list[str]]] = []
    for moment, line in captured:
        if grouped and moment - grouped[-1][0] <= BATCH_SECONDS:
            grouped[-1][1].append(line)
        else:
            grouped.append((moment, [line]))
    return grouped


def wrap(line: str) -> list[str]:
    if len(line) <= COLUMNS:
        return [line]
    return textwrap.wrap(line, COLUMNS, subsequent_indent="      ", break_long_words=True) or [""]


def render_frame(
    font, size: tuple[int, int], command: str, lines: list[str], moment: float
) -> Image.Image:
    width = size[0]
    image = Image.new("RGB", size, BACKGROUND)
    draw = ImageDraw.Draw(image)

    draw.rectangle((0, 0, width, BAR_HEIGHT), fill=BAR)
    draw.text((PADDING, 5), f"$ {command}", font=font, fill=TEXT)

    minutes, seconds = divmod(int(moment), 60)
    label = f"real run, sped up  |  {minutes:02d}:{seconds:02d} of real time"
    label_x = width - PADDING - draw.textlength(label, font=font)
    draw.text((label_x, 5), label, font=font, fill=MUTED)

    y = BAR_HEIGHT + PADDING
    for line in lines[-ROWS:]:
        draw.text((PADDING, y), line, font=font, fill=colour_of(line))
        y += LINE_HEIGHT
    return image


def shared_palette() -> Image.Image:
    """Shades from the background to each colour, so anti-aliased text keeps its true colour."""
    background = ImageColor.getrgb(BACKGROUND)
    values: list[int] = []
    for colour in (TEXT, MUTED, HEADING, GOOD, BAD, BAR):
        target = ImageColor.getrgb(colour)
        for step in range(8):
            values.extend(
                round(start + (end - start) * step / 7)
                for start, end in zip(background, target, strict=True)
            )
    palette = Image.new("P", (1, 1))
    palette.putpalette(values)
    return palette


def write_gif(path: Path, command: str, captured: list[tuple[float, str]]) -> int:
    font = load_font()
    char_width = font.getlength("M")
    size = (
        int(char_width * COLUMNS) + PADDING * 2,
        BAR_HEIGHT + PADDING * 2 + LINE_HEIGHT * ROWS,
    )

    grouped = batches(captured)
    frames: list[Image.Image] = []
    durations: list[int] = []
    shown: list[str] = []
    for index, (moment, new_lines) in enumerate(grouped):
        for line in new_lines:
            shown.extend(wrap(line))
        frames.append(render_frame(font, size, command, shown, moment))
        if index + 1 < len(grouped):
            wait_ms = int((grouped[index + 1][0] - moment) * 1000)
            durations.append(max(MIN_FRAME_MS, min(MAX_FRAME_MS, wait_ms)))
        else:
            durations.append(LAST_FRAME_MS)

    # One shared palette keeps the file small, and stops the text flickering between frames.
    palette = shared_palette()
    converted = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    converted[0].save(
        path,
        save_all=True,
        append_images=converted[1:],
        duration=durations,
        loop=0,
        optimize=False,
        disposal=1,
    )
    return sum(durations)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--command", required=True, help="The command to show in the title bar.")
    parser.add_argument("--out", required=True, help="Output path, without an extension.")
    args = parser.parse_args()

    # Windows defaults to a legacy code page, which would mangle non-ASCII output from kubectl.
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    captured = capture(sys.stdin)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    transcript = "\n".join(line for _, line in captured).rstrip() + "\n"
    out.with_suffix(".txt").write_text(transcript, encoding="utf-8", newline="\n")

    gif = out.with_suffix(".gif")
    length_ms = write_gif(gif, args.command, captured)
    print(
        f"[recorded] {gif}: {gif.stat().st_size / 1_000_000:.1f} MB, "
        f"plays in {length_ms / 1000:.0f}s, from {captured[-1][0]:.0f}s of real time",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
