# Harness output contract

Rota preserves user-visible results, failures and requests for user input.
Provider protocols determine message identity, content and lifecycle; Rota owns
card layout, disclosures and typography. This is a bounded client, not a
reproduction of every harness UI or a promise to read every archive variant.
See [Transcript format](transcript-format.md) for storage and rendering, and
[Harness compatibility](harness-compatibility.md) for native verification.

## Primary sources

| Source | What it establishes | Local authority |
|---|---|---|
| [Codex App Server](https://learn.chatgpt.com/docs/app-server#items) | Typed items, IDs, deltas and authoritative completed items | Generate schemas with the selected executable, including experimental fields enabled by Rota. |
| [Claude Agent SDK streaming](https://code.claude.com/docs/en/agent-sdk/streaming-output) | Message/block boundaries, partial events and completed blocks | Selected CLI help and synthetic stream tests; interactive archives have a separate adapter. |
| [Grok agent mode](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/15-agent-mode.md) | ACP updates and vendor extensions | Installed agent guide, plus a live probe before handling new extensions. |
| [ACP v1 tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls) and [content](https://agentclientprotocol.com/protocol/v1/content) | Status, text/images/resources, diffs, terminal references and permission labels | Grok's negotiated protocol and observed payloads, not assumptions from a newer draft. |
| [Antigravity headless mode](https://antigravity.google/docs/cli/headless/) | Step identity, text deltas, tool results/errors and subagent invocation metadata | Selected CLI help, stream and archive probes. Stream docs do not specify the complete archive format. |
| [MCP tool results](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#tool-result) | Text, images, resource links and embedded resources | The enclosing harness's format; MCP alone does not establish how a harness forwards blocks. |

Documentation examples describe wire shapes, not exhaustive compatibility.
SDK output, app-server history and on-disk terminal records are distinct inputs.
Fixtures are synthetic, shaped after these sources and verified native payloads;
personal session data never belongs in fixtures.

## Event to presentation mapping

| Native concept | Rota presentation | Adapters and regression coverage |
|---|---|---|
| Answer text and block boundaries | Ordered agent entries; deltas append to the matching message | Both Claude hosts, Codex RPC/terminal, Grok live/archive, Antigravity stream/archive. `TranscriptBoundaryTests`, `TranscriptAdapterTests`, `TerminalTranscriptTests`. |
| Exposed reasoning | Separate, collapsed Reasoning disclosure | Same agent adapters; Antigravity supplements its stream from its archive. `TranscriptAdapterTests`, `HarnessContractTests`. Hidden reasoning is never inferred. |
| Tool text and text resources | Literal selectable output, in provider order | Both Claude hosts, Codex RPC/terminal and Grok live/archive share `ToolOutput`; Antigravity preserves string output. `SessionContentTests`, `TranscriptAdapterTests`. |
| Codex `functionCallOutput` | Standalone string or block-array tool output | `CodexItemOutput`; `ToolContentContractTests`. Terminal records retain their separate snake-case types. |
| Tool images | Session-owned preview, readable image label in logs | Claude results, Codex RPC/terminal and Grok ACP/archive, including ACP `uri` references. `SessionContentTests`, `ToolContentContractTests`. Antigravity has no verified structured image result block. |
| File changes | Codex per-file diff disclosures; Grok literal Before/After output | `CodexItemOutput`, `GrokToolOutput`; `SessionContentTests`, `TranscriptAdapterTests`. Generic prose is never guessed to be a diff. |
| MCP resource links | Title/name, MIME type and URI as literal text | Shared block adapters; `ToolContentContractTests`. Display does not fetch or open a resource. |
| Unsupported content blocks | Notice naming the type, with available display metadata/text | Shared block adapters and unknown Grok tool-content wrappers; `ToolContentContractTests`. Supported neighbors retain their order. |
| Tool and run failures | Available failure text and native final outcome | Antigravity stream/archive, Claude result/API errors, Codex error/turn notifications. `SessionContentTests`, `AntigravityTests`. A tool failure does not itself declare the whole run failed. |
| Questions and approvals | Native choices/forms, or an unreadable-dialog notice with Terminal access | `AgentQuestionTests`, `AntigravityQuestionTests`, `ClaudeDialogRecoveryTests`, `LiveQuestionTests`. Choices are never invented from prose. |
| Child-agent activity | Brief parent-session status, separate from its answer | `SessionContentTests`. Antigravity's completed invocation confirms launch, not child completion. |
| Shell stdout/stderr | Existing literal log | Shell has no model content-block protocol. `LiveHarnessTests` covers exit status and Stop. |

## Unsupported content and deliberate limits

`ToolOutput` projects unknown tool content to ordinary text, retaining only
`title`, `name`, `mimeType`, `uri` and `text`; embedded resources use their inner
metadata. Duplicate values appear once. Binary `data`/`blob`, private metadata
and arbitrary nested fields are not serialized; `data:` URIs are omitted from
fallback details. An image with no usable source also gets a notice. Valid images
still use the attachment path, not this textual fallback.

Audio, video and binary documents have no dedicated viewer. Unknown auxiliary
notifications and assistant control blocks remain ignored: rendering every event
would expose bookkeeping and duplicate messages. The fallback applies inside
recognized tool-result containers; a new top-level result kind still requires
semantic review and an adapter test.

ACP terminal references are not terminal output themselves. Rota does not
advertise client-owned terminal creation; Grok command output currently reaches
Rota through tool content. Rich MCP app views, arbitrary structured result
schemas and complete child conversations have no dedicated presentation.

## Verification and maintenance

Run `swift test --filter 'ToolContentContractTests|SessionContentTests|TranscriptAdapterTests|TranscriptBoundaryTests'`
for decoding, journal replay, neighboring content and message boundaries.
`ToolContentContractTests` also checks that opaque bytes and private metadata
never enter either journal. Prove new assertions fail with the old decoder.

`InstalledHarnessContractTests.testInstalledCodexInteractionSchemaMatchesAdapters`
generates the installed schema once for interaction requests and every declared dynamic-output block
through `CodexItemOutput`. Known text/image variants retain their presentation;
others must produce a visible fallback. It does not claim support for every
`ThreadItem` or old rollout format. Interaction-schema checks separately cover
user-input requests.

After adapter changes, run native tool-result tests, including interactive Claude
in an already trusted disposable workspace, and clean up test-owned sessions and
services. `scripts/ui-check.sh --harnesses-only` checks the shipping renderer at
minimum width in both appearances, including fallback text and resource metadata
beside image/diff output. Unsupported-content checks use synthetic data; live
tests establish installed compatibility for ordinary tool results, not emission
of hypothetical future blocks.

## Weekly compatibility review

The project skill [harness-compatibility-weekly](../.claude/skills/harness-compatibility-weekly/SKILL.md)
owns the recurring review. Its live schedule, harness and enabled state belong
to Rota's registration, not a second schedule table here. Public sources live in
its `sources.json`; `scripts/harness_review.py` collects fingerprints with bounded
concurrent requests, preserves manifest order and updates
only explicitly reviewed baselines. Installed contracts export model metadata
through `ROTA_HARNESS_REVIEW_OUTPUT`; raw catalogs stay in task-owned scratch.

The report is `.claude/harness-compatibility-weekly.md`. It links primary evidence,
names affected adapters/tests and proposes concrete changes, prioritizing lost
results, errors, user-input requests and invalid model/effort choices. The routine
writes only its own sanitized state, lessons and report. It preserves unresolved
proposals; application changes remain a separate reviewed task.

Run `uv run python -B -m unittest discover -s scripts/tests -p 'test_harness_review.py' -v`
for unavailable-source handling, explicit review, bounded history, release noise,
code indentation, concurrent collection, damaged state and dry-run persistence. CI runs these checks too. A first review
establishes a baseline, not an invented history of upstream changes.
