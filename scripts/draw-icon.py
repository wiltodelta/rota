#!/usr/bin/env python3
"""Draw Rota's icon: a dial (routines run on a schedule) with a play triangle at
its centre (a run starts). Writes the Icon Composer document `App Icon.icon`
(layers and icon.json) and the template menu bar icons in `MenuIcons.xcassets`
from one geometry, so its files are regenerated here, never edited by hand.

Every shape is a closed filled outline: Icon Composer's macOS 26 renderer fills
a stroked open path across its chord, which once drew a solid disc in the dark
appearance."""

import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024
CENTER = SIZE / 2
FACE_RADIUS = 360
TICK_OUTER = 300
TICK_LENGTH, MAJOR_TICK_LENGTH, TICK_WIDTH = 50, 75, 34
PLAY_SIZE, PLAY_SHIFT, PLAY_ROUNDING = 118, 22, 20

# The menu bar glyph: the dial as a ring with twelve hour dots, the app icon's
# ticks reduced to what reads at 18 pt with the weight of the system's symbols.
MENU_RING_RADIUS, MENU_RING_WIDTH = 430, 84
MENU_DOTS, MENU_DOT_ORBIT, MENU_DOT_RADIUS = 12, 330, 34
MENU_PLAY_SIZE = 160
MENU_INSET = CENTER - MENU_RING_RADIUS - MENU_RING_WIDTH / 2

TEAL = ["extended-srgb:0.17647,0.83137,0.74902,1.00000", "extended-srgb:0.03137,0.42745,0.35686,1.00000"]
DEEP_TEAL = "srgb:0.03137,0.42745,0.35686,1.00000"
WHITE = "srgb:1.00000,1.00000,1.00000,1.00000"
ORANGE = "srgb:1.00000,0.62745,0.25098,1.00000"


def ticks():
    """The app icon's hour ticks: rounded bars pointing at the centre, one per
    hour from 12 o'clock, the quarter hours longer."""
    bars = []
    for hour in range(12):
        length = MAJOR_TICK_LENGTH if hour % 3 == 0 else TICK_LENGTH
        bars.append(f'<rect x="{CENTER - TICK_WIDTH / 2:.1f}" y="{CENTER - TICK_OUTER:.1f}" width="{TICK_WIDTH}" '
                    f'height="{length}" rx="{TICK_WIDTH / 2}" fill="{{color}}" '
                    f'transform="rotate({hour * 30} {CENTER} {CENTER})"/>')
    return "".join(bars)


def circle_path(cx, cy, r):
    return f"M{cx - r:.1f} {cy:.1f} a{r} {r} 0 1 0 {2 * r} 0 a{r} {r} 0 1 0 {-2 * r} 0 Z"


def hour_dots():
    """The menu bar dial's hour marks, one dot per hour from 12 o'clock, as path data."""
    dots = []
    for hour in range(MENU_DOTS):
        a = math.radians(hour * 360 / MENU_DOTS)
        dots.append(circle_path(CENTER + MENU_DOT_ORBIT * math.sin(a), CENTER - MENU_DOT_ORBIT * math.cos(a),
                                MENU_DOT_RADIUS))
    return " ".join(dots)


def play_outline(size=PLAY_SIZE):
    """A triangle with rounded corners, nudged right to sit optically centred."""
    s, x, r = size, CENTER + PLAY_SHIFT * size / PLAY_SIZE, PLAY_ROUNDING * size / PLAY_SIZE
    corners = [(x - s * 0.6, CENTER - s), (x + s * 0.92, CENTER), (x - s * 0.6, CENTER + s)]
    parts = []
    for i, (cx, cy) in enumerate(corners):
        (px, py), (nx, ny) = corners[i - 1], corners[(i + 1) % 3]
        a = _toward(cx, cy, px, py, r)
        b = _toward(cx, cy, nx, ny, r)
        parts.append(f'{"M" if i == 0 else "L"}{a[0]:.1f} {a[1]:.1f} Q{cx:.1f} {cy:.1f} {b[0]:.1f} {b[1]:.1f}')
    return " ".join(parts) + " Z"


def _toward(x0, y0, x1, y1, distance):
    length = math.hypot(x1 - x0, y1 - y0)
    return x0 + (x1 - x0) * distance / length, y0 + (y1 - y0) * distance / length


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


def layer(name, fills, glass=True):
    return {"fill-specializations": fills, "glass": glass, "image-name": f"{name}.svg", "name": name}


def group(*layers):
    return {"layers": list(layers), "lighting": "individual", "shadow": {"kind": "neutral", "opacity": 0.5},
            "specular": True, "translucency": {"enabled": False, "value": 0.5}}


def icon_document():
    # Layers run top to bottom. The play and the ticks are printed on the
    # face's glass: as glass of its own the play went white on the white face
    # in the clear and tinted appearances, and tinted it takes the ticks' dark
    # teal, since the orange turns pale once the system reduces it to one hue.
    return {
        "fill": {"linear-gradient": TEAL},
        "groups": [
            group(layer("play", [{"value": {"solid": ORANGE}},
                                 {"appearance": "tinted", "value": {"solid": DEEP_TEAL}}], glass=False),
                  layer("ticks", [{"value": {"solid": DEEP_TEAL}}], glass=False),
                  layer("face", [{"value": {"solid": WHITE}}])),
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }


def main():
    icon = ROOT / "App Icon.icon"
    assets = icon / "Assets"
    for stale in assets.glob("*.svg"):
        stale.unlink()
    write(assets / "face.svg", svg(f'<circle cx="{CENTER}" cy="{CENTER}" r="{FACE_RADIUS}" fill="{{color}}"/>',
                                   "white"))
    write(assets / "ticks.svg", svg(ticks(), "white"))
    write(assets / "play.svg", svg(f'<path d="{play_outline()}" fill="{{color}}"/>', "white"))
    write(icon / "icon.json", json.dumps(icon_document(), indent=2) + "\n")
    catalog = ROOT / "MenuIcons.xcassets"
    write(catalog / "Contents.json", '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    play, dots = play_outline(MENU_PLAY_SIZE), hour_dots()
    idle = (f'<circle cx="{CENTER}" cy="{CENTER}" r="{MENU_RING_RADIUS}" fill="none" stroke="{{color}}" '
            f'stroke-width="{MENU_RING_WIDTH}"/>'
            + f'<path d="{dots}" fill="{{color}}"/>'
            + f'<path d="{play}" fill="{{color}}"/>')
    # Running: a solid disc with the dots and the play cut out, as SF Symbols pairs
    # an outline with its .fill; a filled play inside the same ring was too small a
    # change to see.
    disc = circle_path(CENTER, CENTER, MENU_RING_RADIUS + MENU_RING_WIDTH / 2)
    running = f'<path d="{disc} {dots} {play}" fill="{{color}}" fill-rule="evenodd"/>'
    for name, body in (("MenuIcon", idle), ("MenuIconActive", running)):
        filename = f"{name}.svg"
        write(catalog / f"{name}.imageset" / filename, svg(body, "black", inset=MENU_INSET))
        write(catalog / f"{name}.imageset" / "Contents.json", imageset(filename))


if __name__ == "__main__":
    main()
