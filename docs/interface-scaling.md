# Interface scaling

Research snapshot: October 13, 2026. This decision covers the two controls in
Rota, app zoom and chat text size. It does not introduce separate sidebar,
terminal, icon or code-size preferences.

## Reference behavior

| Question | super.engineering | VS Code | Rota |
|---|---|---|---|
| What does app zoom change? | Interface text and geometry, including icons and the sidebar | The renderer's entire page, including text, icons, spacing and controls | Actual font sizes and layout dimensions in points |
| What does content font size change? | Chat has its own multiplier and commands | Chat Markdown and code blocks have separate font settings | Transcript and composer text, with the existing prose/code font families |
| App zoom default | 100% | Level 0, or 100% | 100% |
| App zoom step | 10 percentage points | One level; factor is `1.2 ** level` | 10 percentage points |
| App zoom bounds | 50-200% | The inspected command implementation clamps levels to -8 through 8 | 50-200% |
| Chat size | Effective multiplier is bounded to 50-200% | Markdown defaults to 13 CSS px; the installed setting schema accepts 6-100 | Effective body size is bounded to 7-28 pt, with 14 pt at 100% |

CSS pixels and AppKit points are different platform units. The numerical font
defaults are not a reason to copy the same physical font size between apps.
VS Code's level step is multiplicative: levels 0, 1 and 2 mean 100%, 120% and
144%, not 100%, 120% and 140%.

### super.engineering evidence

Inspected the installed build `ac45e7aa`, its native View menu, rendering, saved
UI scale, and retained symbols/instructions for UI-scale normalization and
`next_chat_text_multiplier`. The compiled initial UI scale is 1.0. The menu
exposes app, chat, editor and terminal text commands separately.

A live 100% to 110% comparison showed the sidebar growing from approximately
340 to 375 pixels in equal-width captures, with its icons and row geometry
also growing. These are screenshot coordinates, not claimed AppKit point
measurements. The saved UI scale was read back at its original 110% afterwards.
The user navigated between sessions during the comparison, so message content
was not treated as a paired font measurement.

The inspected chat adjustment computes the effective multiplier from app
scale and a saved relative multiplier. Its effective bounds are 0.5-2.0, its
stored relative bounds are 0.25-4.0, and each step changes the effective value
by `0.1 * appScale`. Changing app scale preserves the relative preference.
This verifies the adjustment arithmetic, not every private rendering path or
the reference's chat-reset behavior at non-default app zoom.

### VS Code evidence

Inspected VS Code 1.141.0, commit
`2a59476c9bfcb90b3ddc372c36762471b7dfad1c`, on a disposable user-data profile.
The native View > Appearance > Zoom In command visibly enlarged activity-bar
icons, the tab bar, text and controls together. The installed workbench's
configuration registration confirms the Markdown font default and schema
bounds above. These bounds describe setting validation, not an independently
tested renderer clamp.

The pinned [window implementation](https://github.com/microsoft/vscode/blob/2a59476c9bfcb90b3ddc372c36762471b7dfad1c/src/vs/platform/window/electron-browser/window.ts)
calls Electron's `webFrame.setZoomLevel`, clamps levels to -8 through 8, and
increments or decrements by one. The pinned [factor conversion](https://github.com/microsoft/vscode/blob/2a59476c9bfcb90b3ddc372c36762471b7dfad1c/src/vs/platform/window/common/window.ts)
uses `1.2 ** zoomLevel`. The [accessibility documentation](https://code.visualstudio.com/docs/configure/accessibility/accessibility)
describes the zoom commands and persistence in `window.zoomLevel`.
The [chat documentation](https://code.visualstudio.com/docs/chat/chat-overview#customize-the-chat-display)
separates `chat.fontFamily` / `chat.fontSize` from code-block font and line-height
settings. Chat-specific settings were checked in documentation and installed
code; the live rendering comparison used the text editor, not a provider chat.

## Rota's decision

Keep the reference distinction explicit in both labels and behavior:

- **App zoom**, in Settings > General and View, changes interface text, vector
  icons, spacing, rows and content controls together. It preserves the
  hierarchy between body text, metadata and headings. Native window chrome,
  menu rows and settings-tab symbols remain under macOS control. Native toolbar
  symbols scale with app zoom, with a 10 pt symbol minimum, inside regular
  borderless controls. Content button styles are scoped to the split-view panes.
  On macOS 26, their shared glass background is hidden to avoid
  nested rounded bezels. The View menu separates full-screen mode from the
  text-size commands.
- **Chat text size**, in Settings > Chat and View, changes prose, code and the
  composer without changing interface icons, sidebars, control targets or
  transcript column margins. Text reflows and the transcript scrolls. Code
  remains 90% of prose size; it does not get another size control.
- Both settings display percentages and provide decrease, increase and reset
  actions. App zoom returns to 100%; chat reset restores an effective 14 pt
  while leaving app zoom alone. This last behavior is Rota's explicit choice,
  rather than a claim of exact reset parity with the reference.

Do not selectively freeze content icons while scaling their adjacent text:
both inspected references enlarge icons under app zoom. Do not apply a bitmap
transform to achieve the same visual result. Rota resolves new font sizes and
vector geometry before drawing, following [AppKit's point/backing-resolution model](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Introduction/Introduction.html).
Minimum targets remain 20 pt. Sheets and forms scroll at their available
bounds, and the main split view reserves usable detail space at 820 pt.

Implementation details and capture hooks are in [architecture.md](architecture.md).
Verification must cover both appearances at 820 pt, app scales 50%, 100%,
110% and 200%, chat resizing with stable interface geometry, disabled limit
actions, reset independence, native picker selection and text selection.

The font-only regression test exercises the shipping `TranscriptScrollView`
with 14 pt and 28 pt native fonts. It requires taller reflowed text while
keeping the scroll-view frame, column width, margins and selection unchanged.
A disposable source-copy mutation that derives interface scale from font size
compiled successfully and failed those geometry assertions. The live Settings
check also compared Send, Attach Files and Show Log in Finder frames before
and after chat reset with app zoom held at 200%; their geometry was unchanged.

Shrinking selected text also exercises the native scroll viewport. After the
text document changes size, its requested scroll origin is constrained with
`NSClipView.constrainBoundsRect`; otherwise an old offset can leave all fitting
text outside the visible area. The regression test resizes 28 pt text to 7 pt
while preserving selection and requires all fitting glyphs to remain visible.

A disposable mutation removing that viewport constraint compiled and failed
only the selected-text shrink regression. The Accessibility tree alone did not prove a visible separator: SwiftUI
reported an empty menu item while the rendered menu had no divider.
`FullScreenMenuSeparator` repairs the native menu after AppKit inserts its
full-screen command, including when SwiftUI leaves a hidden trailing divider.

Final native captures covered light and dark appearances at an 820 pt window
width, with app zoom at 50%, 100% and 200%. All captures passed the layout gate
and were visually inspected. Pixel bounds of the toolbar plus symbol confirmed
that its size approximately doubles from 100% to 200%, while the surrounding
native hit target remains usable. SwiftLint, the complete non-live test run,
and the signed bundle build passed. Live harness tests were skipped; no real
routine was fired during the scaling checks.

The corrected separator was verified in a signed, separately identified review
bundle with an empty data directory. Native menu captures showed the line
between Reset Chat Text Size and Enter Full Screen with light and dark windows,
including at the 820 pt minimum width. Menu appearance remains macOS-owned.
The hidden-divider regression passes and a disposable mutation ignoring
`isHidden` fails it. The development app initially remained on its older build while its routine
ran. After the run ended, the verified bundle was reopened with the menu fix
and readable composer model labels.
