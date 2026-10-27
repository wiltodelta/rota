# Transcript format

Rota supports a small common presentation subset: user and agent messages,
provider-exposed reasoning, generic tool activity, and informational or error notices. Plans are optional
existing metadata. Runner adapters select these kinds; provider event names
and tool schemas never reach the view. Unknown auxiliary provider events are
ignored, while supported text in neighboring blocks is retained. Transport
and execution failures remain runner failures.

## Storage and ownership

New agent sessions have a readable `<session>.log` and an adjacent
`<session>.log.chat.jsonl`. `RunJournal` owns both writers under one lock.
The normalized file contains only Rota records, never raw provider payloads.
`TranscriptJournal` handles JSONL encoding; `TranscriptReader` incrementally
replays it into `TranscriptSnapshot`. IDs are allocated once per session and
continue above existing IDs on resume, including repeated identical messages.

Every record has `version: 1`, `type`, and `logSize`, the readable log's byte
length after the corresponding write. Supported record types are:

| Type | Fields | Meaning |
|---|---|---|
| `header` | No additional fields | Opens the journal, exactly once. |
| `item` | `id`, `kind`, `text`, optional `complete` | Adds an ordered entry. `complete` defaults to true. |
| `append` | `id`, `text` | Appends text to an incomplete entry, preserving its ID. |
| `complete` | `id` | Completes an incomplete entry. This does not finish the run. |
| `checkpoint` | `required: false` | Accounts for diagnostic log metadata with no chat entry. |

Kinds are `user`, `agent`, `tool`, `status`, `error`, `output`, and optional
`plan` and `reasoning`. Agent and reasoning text can use append records. A partial message is
persisted as chunks arrive; its readable log text is flushed before the next
entry or run completion. All other messages can be delivered complete.
Optional `sourceID` on records identifies durable source frames; `nativeID`
on items identifies native messages across coalesced replay and live chunks.
The journal restores unfinished items and recovery indexes before appending.
UI readers do not retain that recovery-only source index. Provider-exposed
reasoning is collapsed behind Reasoning; tool output remains tool activity.
Empty or whitespace-only reasoning stays in the journal but creates no chat row
and does not split adjacent tool calls. This applies to legacy turn grouping too.
Readable logs use `[reasoning]` and `[output]` prefixes as well.
Claude stream deduplication tracks nonempty answer and reasoning deltas separately:
receiving one never suppresses an unstreamed completed block of the other kind.
Grok tool text and textual file diffs share one decoder for live ACP updates
and newly appended terminal history. Native event IDs distinguish revised results
from repeated delivery at the same tool/block index; older events without IDs keep
their existing index-based fallback. Antigravity reads available native reasoning
before recording the next tool event, as well as before answer text and results.
These adapters apply to new events; opening an old journal does not backfill it
from a provider archive or rewrite its records.
The scheduler's `RunRecord` remains the authority for run outcome and attention.

Continuing an existing normalized session validates and appends its journal.
An unreadable or unsupported existing journal is not overwritten; the session
continues through the readable log with an error notice. Failure to open the
optional presentation store does not prevent execution. Continuing a legacy
session without a journal keeps writing its legacy log. Shell uses
its existing plain-output path and creates no normalized journal.

## Compatibility and failure behavior

Unknown fields are ignored. Unknown record types are skipped only when they
explicitly carry `required: false`. An unknown presentation kind with a valid
`text` field displays as a plain notice. Unknown versions, unknown required
records, malformed records, duplicate IDs, or invalid updates cause an explicit
incomplete-history warning and fallback to the readable log. A final incomplete
JSONL line is held during a live read and reported if the session has ended.

The files are not a transaction. A reader compares the journal's last accepted
`logSize` against the readable log. If the readable write succeeded but the
normalized write did not, it falls back with a warning rather than showing a
stale chat as complete. The UI keeps the last coherent structured snapshot across one inconsistent
live poll. If the next poll is still inconsistent, or the run has finished,
it shows the warning and readable fallback. A coherent read resets this grace
period. Malformed or unsupported complete records fail immediately. Writer
validation on continuation has no grace period. A normalized write failure also adds a readable
error and stops further normalized writes for that run. It does not reinterpret
the agent's execution result. Readable-log I/O retains the existing writer's
behavior; this change does not introduce a general storage-recovery service.

Normalized history preserves complete entries instead of cutting at a byte
offset. The UI targets the latest 50 entries by reading backwards in 32 KB blocks,
then reads only appended bytes while polling. Load Earlier Messages targets
another 50 entries. A page extends backwards through any leading tool calls
and output to their preceding non-tool entry or the journal header. Calls and
output share `TranscriptItem.Kind.canJoinToolGroup` with presentation, so a
page cannot detach output or change already loaded group IDs when prepended.
The count is a soft target: a large tool group is loaded whole. A message and
all its text chunks also form one unit, so a single very large message still
needs its entire content. Older records are
validated when their page is loaded, not claimed to have been checked at open.
The header is always validated. The producer completes a streamed entry before
introducing the next entry; paging relies on that ordering. Continuation still
validates the whole journal. Legacy and Shell reads retain their existing 400 KB tail limit.
Retention, individual session deletion, and routine deletion remove both files
together. Manual session deletion requires confirmation and protects active
sessions; ownership and failure handling are described in [Architecture](architecture.md).

## Presentation and extension boundary

`SessionView` owns a `TranscriptSessionReader` actor for its session and polls
it while the run is active. Polling and page requests share that reader off the
UI actor; scheduler refreshes and run completion retain already loaded pages.
The view changes state only when the snapshot changes. A pending page request
supersedes any older poll result. A finished session moves its trailing status
entry matching the run outcome into one footer with the completion time, result, and duration. It does not
repeat the status as a transcript row or offer a bulk Copy action. Earlier status
entries from continued runs remain in order, and a missing final status uses the
run record outcome. Legacy sessions share the footer without Copy. Normalized entries render
in their recorded order with stable IDs and SwiftUI scroll targets. Adjacent tool
calls and their intervening output form a collapsed group labeled with the number
of loaded calls, including a single call. Expanding reveals complete, selectable
titles and output in order, with wrapping. Standalone output stays visible.
Agent text, errors and other kinds end the group and stay visible. This is a view projection over the existing items, not a journal change.
Expansion belongs to the session view and survives live appends. Paging preserves
existing tool groups instead of extending their leading edge. The reading-anchor
mapping remains defensive for regrouped snapshots; toggling preserves the header
offset instead of following the end.
The ordered presentation does not infer which prose is a final answer from
the last tool call. Legacy logs
retain their inferred turn layout. Markdown, typography, copy actions, and
the composer reuse existing components.

Scroll targets, including the end marker, use the same ID type. Mixing a
string end marker with integer message targets can leave the latest-message
action short of the end after lazy layout changes. At a page boundary the
load button can be the first visible element, leaving no message target.
Invisible native row markers capture the first fully visible message's
actual offset. Keep the ID scroll-position binding alongside the proxy and pixel
correction: removing it in the synthetic prepend check lost the reading position.
The reading anchor is saved during scrolling, before new data
changes layout; capturing it only in the update callback can already see the
moved row. A narrow `TranscriptViewport` bridge restores that offset after
layout; an ID alone does not correct SwiftUI's changing lazy height estimates.
A page request captures its anchor before I/O, materializes that row after the
page arrives, and then corrects the pixel offset. User scrolling and the
latest-message action cancel queued corrections. Layout changes do not resume following;
scrolling back to the end or pressing the latest-message button does.

New optional metadata should enrich an existing entry without being necessary
to read basic text or finish a run. Specialized tool cards, arbitrary provider
blocks, queue management, approval forms, and raw payload archives are outside
this contract. CLI changes to core framing, text delivery, or lifecycle can
still require an adapter update. Full compatibility with every CLI release is
not promised.

Tests in `TranscriptJournalTests` exercise the writer-to-reader seam, unknown
neighbors, compatibility fallbacks, partial Unicode messages, replay and resume.
Assertions about normalized replay must require `structured == true` and no
problem: equality of displayed text alone can pass through the legacy fallback
even when ID allocation is broken. Mutation checks run on disposable copies.
The existing `LiveHarnessTests` also validate normalized history for real agent
runs. UI checks must include synthetic normalized data, not just Shell logs.

The initial implementation was rendered through the signed development bundle
with producer-generated synthetic data at the 820-point minimum width, in
light and dark appearances. Normalized and unsupported-history fallback states
passed bounds checks; calibrated samples of secondary text passed contrast
checks. The latest-message action and legacy work expansion were exercised
through Accessibility. Live runner checks covered sending, continuation,
stopping, and normalized replay. Partial-text rendering was checked at the
writer/reader seam, not through a live GUI conversation; selection-drag
anchoring and performance improvements are not claimed by this verification.

The paging follow-up was checked with producer-generated long history in the
signed development app at 820 points, in both appearances. Page insertion kept
the existing message at the same screen coordinate. The shipping chat component
was also hosted with synthetic updates: Markdown growth above the reading
position, streamed text below it, page insertion, and returning to the latest
message. Reading coordinates stayed fixed across those updates; following at
the end resumed correctly. Bounds checks and calibrated contrast checks passed.
These are synthetic GUI updates, not new live-provider conversations.
`TranscriptPagingTests` verifies bounded journal I/O, page reconstruction,
write settling and failure recovery. `TranscriptViewportTests` uses real
`NSScrollView` geometry to pin saved reading offsets and correction cancellation.
Disposable mutation checks reject full-file paging, indefinite write settling,
disabled pixel correction, and recapturing an already moved reading anchor.

Tool grouping was rendered in the signed development bundle with producer-generated
synthetic history, collapsed and expanded in light and dark at 820 by 600 points,
and at 1100 by 720 points. Accessibility presses expanded and collapsed the
14-call group and exposed full wrapped titles. Header position stayed unchanged
through both transitions; controls measured 28 points high and the layout gate
reported no overflow. Calibrated pixel samples passed text contrast in both
appearances. Keyboard activation was not established: AX focus stayed in the
composer, so the guarded Space probe sent no key. `ToolGroupingTests` checks
all non-tool boundaries, repeated calls, live append identity and prepended
page mapping; a disposable mutation that grouped agent text fails those checks.
Page-boundary regression tests use `RunJournal` output to require whole tool
and output groups on the first page, unchanged existing rows after prepend,
and a group larger than the page target at the start of a journal.
Set `ROTA_PAGING_GROUP_FIXTURE_DIR` on the boundary test to export its synthetic
app data. Set `ROTA_TOOL_FIXTURE_DIR` while running the presentation fixture
test to export synthetic app data for the disclosure UI check. This verification uses synthetic history,
not a live provider conversation.

The page-boundary fix was also checked in the signed development bundle at
820 by 680 points in both appearances, opening it through `ROTA_OPEN_PANEL=1`
and Open Rota. A group with two calls and two outputs straddling the former
cut stayed expanded after Load Earlier Messages; its header kept the same
screen coordinate, and it could still collapse. Bounds checks passed. The
captured frames and text recognition confirmed that both calls and outputs
remained rendered, independently of their Accessibility bounds.

The completion footer follow-up was checked in the signed development app at
820 by 600 points in both appearances using producer-generated synthetic data.
The Accessibility regression check found two completion rows and a bulk Copy
button before the fix, and one combined completion row without that button after
it. Legacy logs and a legacy log missing its final status also retained exactly
one completion row. Code-block Copy remained available. Bounds checks and
calibrated text contrast passed; `transcriptCompletion` identifies the footer.

## File references in user messages

User text may end with `ChatMessage`'s `[Rota attachments v1]` JSON manifest.
The journal still stores an ordinary user item's text, with no schema bump.
Rota renders valid manifests as filename chips; agent adapters receive the same
text with local file paths. Copies live in the log's `.attachments` companion
folder and follow its retention. Claude stream, Codex and Grok additionally receive validated native image
inputs through `HarnessInput`. Other modes and other files use local tool
access; this does not promise native document uploads. Invalid manifests remain
literal text. Original files are never removed by session cleanup.
