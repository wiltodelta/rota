#!/usr/bin/env python3
"""Draw Rota's icon glyph: a loop arrow (a routine comes round again) around a
play triangle (it runs). Writes the Icon Composer layers in `App Icon.icon` and
the template menu bar icons in `MenuIcons.xcassets` from one geometry, so the
SVGs are regenerated here, never edited by hand."""

import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024
CENTER = SIZE / 2
RADIUS = 290
RING = 90
ARC_START, ARC_END = -62, 236  # y-down degrees; the arc runs clockwise, leaving a gap at the top
HEAD_LENGTH, HEAD_HALF_WIDTH, HEAD_BEND = 120, 94, 16
PLAY_SIZE, PLAY_SHIFT = 118, 22
MENU_INSET = CENTER - RADIUS - RING / 2 - 20  # the ring's outer edge plus a hair for the arrowhead


def point(angle):
    t = math.radians(angle)
    return CENTER + RADIUS * math.cos(t), CENTER + RADIUS * math.sin(t)


def loop_paths():
    x0, y0 = point(ARC_START)
    x1, y1 = point(ARC_END)
    arc = (f'<path d="M{x0:.1f} {y0:.1f} A{RADIUS} {RADIUS} 0 1 1 {x1:.1f} {y1:.1f}" '
           f'stroke="{{color}}" stroke-width="{RING}" stroke-linecap="round" fill="none"/>')
    a = math.radians(ARC_END)
    tx, ty = -math.sin(a), math.cos(a)  # clockwise tangent
    nx, ny = math.cos(a), math.sin(a)  # outward normal
    bend = math.radians(HEAD_BEND)  # turn the head toward the centre so it follows the ring
    dx, dy = math.cos(bend) * tx - math.sin(bend) * nx, math.cos(bend) * ty - math.sin(bend) * ny
    px, py = -dy, dx
    tip = (x1 + dx * HEAD_LENGTH, y1 + dy * HEAD_LENGTH)
    b1 = (x1 + px * HEAD_HALF_WIDTH, y1 + py * HEAD_HALF_WIDTH)
    b2 = (x1 - px * HEAD_HALF_WIDTH, y1 - py * HEAD_HALF_WIDTH)
    head = (f'<path d="M{tip[0]:.1f} {tip[1]:.1f} L{b1[0]:.1f} {b1[1]:.1f} L{b2[0]:.1f} {b2[1]:.1f} Z" '
            'fill="{color}" stroke="{color}" stroke-width="30" stroke-linejoin="round"/>')
    return arc + "\n  " + head


def play_path(filled=True):
    s, x = PLAY_SIZE, CENTER + PLAY_SHIFT
    d = f"M{x - s * 0.6:.1f} {CENTER - s:.1f} L{x + s * 0.92:.1f} {CENTER:.1f} L{x - s * 0.6:.1f} {CENTER + s:.1f} Z"
    if filled:
        return f'<path d="{d}" fill="{{color}}" stroke="{{color}}" stroke-width="40" stroke-linejoin="round"/>'
    return f'<path d="{d}" fill="none" stroke="{{color}}" stroke-width="64" stroke-linejoin="round"/>'


def svg(body, color, inset=0):
    """`inset` crops the canvas to the glyph: the app icon needs its margins, a
    menu bar image should fill its 18 pt like the system's."""
    side = SIZE - 2 * inset
    return (f'<svg width="{side}" height="{side}" viewBox="{inset} {inset} {side} {side}" fill="none" '
            f'xmlns="http://www.w3.org/2000/svg">\n  {body.format(color=color)}\n</svg>\n')


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def imageset(filename):
    return ('{\n  "images" : [\n    {\n      "filename" : "' + filename + '",\n      "idiom" : "mac"\n    }\n  ],\n'
            '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "properties" : {\n'
            '    "preserves-vector-representation" : true,\n    "template-rendering-intent" : "template"\n  }\n}\n')


def main():
    assets = ROOT / "App Icon.icon" / "Assets"
    write(assets / "loop.svg", svg(loop_paths(), "white"))
    write(assets / "play.svg", svg(play_path(), "white"))
    catalog = ROOT / "MenuIcons.xcassets"
    write(catalog / "Contents.json", '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    # Idle: an outlined play; running: a filled one, so the state reads at menu bar size.
    for name, filled in (("MenuIcon", False), ("MenuIconActive", True)):
        filename = f"{name}.svg"
        body = loop_paths() + "\n  " + play_path(filled)
        write(catalog / f"{name}.imageset" / filename, svg(body, "black", inset=MENU_INSET))
        write(catalog / f"{name}.imageset" / "Contents.json", imageset(filename))


if __name__ == "__main__":
    main()
