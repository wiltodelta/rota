# Harness logos (`HarnessLogos.xcassets`)

Each harness's own mark, shown beside its answers, in the composer, and in
routine and session lists in the sidebar, routine history and menu bar panel. The
marks are the owners' trademarks; they identify the service they belong to.

Sidebar and menu panel rows use `HarnessStatusIcon` as their primary marker:
a 20 pt monochrome mark in a 24 pt slot, with the existing status dot or
session spinner in its bottom trailing corner. A 1.5 pt background halo
separates the badge from the mark. Captions keep the harness name without
repeating the logo. Routine history uses `HarnessMetadata`, a 12 pt monochrome
mark with a 4 pt gap beside its metadata. All dimensions scale with interface
zoom. Names stay accessible; decorative marks are hidden from VoiceOver and
status badges keep their spoken state. Routine marks follow current settings;
session marks use the run's harness snapshot. Chat and composer marks retain
their 14 pt size.
Metadata marks use the primary text color, including the native selection
color. The chat keeps Claude's orange; small list marks stay monochrome for
contrast on gray sidebar and panel backgrounds. Selected sidebar text uses a
contrasting black or white foreground from `SidebarText`; selected monochrome
harness marks use that foreground too.

`RunActivityIndicator` rotates an asymmetric 8 pt arc once every 1.2 seconds
using `TimelineView`, matching the composer's stop ring. The open arc makes
motion visible at badge size; Reduce Motion pauses the timeline. Its light/dark foreground stays legible
on the badge halo even when the row is selected; the native mini progress
view became white on its light halo in a selected row.

- `harness-claude`: the Claude mark, from Simple Icons (`claude`, CC0 SVG data), as super.engineering shows Claude Code sessions.
- `harness-codex`: OpenAI, from Simple Icons (`openai`, CC0 SVG data). Codex
  publishes no separate mark outside its app.
- `harness-grok`: the Grok mark, cut from the two glyph paths of
  `https://grok.com/images/favicon.svg` (the app-icon background left out).

Antigravity currently uses the system `sparkles` symbol as a neutral fallback;
it is not presented as the vendor's trademark. Shell uses `apple.terminal`.
