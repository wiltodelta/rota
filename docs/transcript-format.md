# Transcript format

Rota supports a small common presentation subset: user and agent messages,
generic tool activity, and informational or error notices. Plans are optional
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
`plan`. Only `agent` text currently uses append records. A partial message is
persisted as chunks arrive; its readable log text is flushed before the next
entry or run completion. All other messages can be delivered complete.
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
offset. The UI opens the latest 50 entries by reading backwards in 32 KB blocks,
then reads only appended bytes while polling. Load Earlier Messages prepends
another 50 entries. A message and all its text chunks form one unit, so a
single very large message still needs its entire content. Older records are
validated when their page is loaded, not claimed to have been checked at open.
The header is always validated. The producer completes a streamed entry before
introducing the next entry; paging relies on that ordering. Continuation still
validates the whole journal. Legacy and Shell reads retain their existing 400 KB tail limit.
Retention and explicit routine deletion remove both files together.

## Presentation and extension boundary

`SessionView` owns a `TranscriptSessionReader` actor for its session and polls
it while the run is active. Polling and page requests share that reader off the
UI actor; scheduler refreshes and run completion retain already loaded pages.
The view changes state only when the snapshot changes. A pending page request
supersedes any older poll result. The footer copies loaded agent messages and
labels that scope while earlier pages remain. Normalized entries render
in their recorded order with stable IDs and SwiftUI scroll targets. They do
not infer which prose is a final answer from the last tool call. Legacy logs
retain their inferred turn layout. Markdown, typography, copy actions, and
the composer reuse existing components.

Scroll targets, including the end marker, use the same ID type. Mixing a
string end marker with integer message targets can leave the latest-message
action short of the end after lazy layout changes. At a page boundary the
load button can be the first visible element, leaving no message target.
Invisible native row markers capture the first fully visible message's
actual offset. The reading anchor is saved during scrolling, before new data
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
