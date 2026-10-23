# README screenshots

These are captures of the signed development app with synthetic routines and
conversations. All routines are disabled; no agent or shell routine is started.
The installed release and its data are not used.

From the repository root:

```bash
scripts/capture-screenshots.sh
```

The recipe builds the app, compiles the existing Accessibility driver and the
native window capture helper, writes the fixtures into a temporary data
folder, and captures light and dark appearances without changing the system
appearance. Agent executable overrides prevent model-catalog initialization;
normal installed-CLI discovery may still read `--version`. It restores the
development app's defaults and quits its own app process on exit. Close an
existing repository development build first; the
script refuses to take it over.

ScreenCaptureKit composites can omit sidebar text fragments after resizing,
even when the native window capture contains all the text. The helper uses
`screencapture -l` with its own opaque backdrop behind the window, then adds the
same backdrop margin in sRGB. It never repairs or replaces interface pixels.

Accessibility and Screen Recording must already be allowed for the invoking
terminal. The shared `macaudit.py` helper provides the unlocked-session check
and on-screen driving notice. The script looks in the maintainer's shared
configuration checkout; set `ROTA_MACAUDIT` to use a different helper location.
If another capture session owns the notice, wait for it to finish.

`ROTA_SCREENSHOT_OUT` overrides the output directory. The default is this
folder. Keep the PNGs and their recipe together when updating them.

| Files (each in light and dark) | State | Window size |
| --- | --- | --- |
| `sessions-*.png` | Completed code review with the routine and session sidebar | 1000 × 680 pt |
| `sessions-minimum-*.png` | The same session at the minimum supported width | 820 × 680 pt |
| `questions-*.png` | Weekly report with an unanswered choice | 820 × 680 pt |
| `schedule-*.png` | The report's routine, schedule, and history | 820 × 680 pt |

Each capture must pass the existing Accessibility layout gate at its stated
size. The images include a 32 pt margin and use the display's backing scale.
`capture-window.swift` captures only the target window over its opaque
backdrop in sRGB, so other windows cannot leak through the glass. The capture
helper does not paint or replace the app's interface.

Inspect every regenerated PNG before using it. The README uses `<picture>`
to choose its appearance, with the light image as the fallback.
