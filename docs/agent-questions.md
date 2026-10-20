# Agent questions

Rota distinguishes suspended protocol requests from asynchronous message questions.
An acknowledgment from the agent runtime is not evidence that Rota displayed a form.
Provider text alone never becomes a question: the adapter requires structured metadata.

## Protocol inventory

The inventory was checked against Claude Code 2.1.304, Codex CLI 0.163.0's
experimental JSON schema and Grok Build 1.0.62's installed guide and native requests.
Recheck those producers when upgrading a runner; fixtures are examples, not the schema.
Grok's live `initialize` response advertises capabilities and hook metadata but
not a complete list of interaction methods. This is a release-specific inventory,
not a claim to recognize every future vendor extension.

| Provider | Incoming request | Answer path | Lifetime |
| --- | --- | --- | --- |
| Codex | `item/tool/requestUserInput`, legacy `tool/requestUserInput` | RPC `answers`, keyed by question id | Until answer or `serverRequest/resolved` |
| Codex | Completed `agentMessage` with `questions`, emitted by `request_user_input_async` | Explicit user message, steering or continuing the same thread | Durable until an explicit answer/cancel/decline |
| Codex | `item/commandExecution/requestApproval` | Exact offered decision, including policy amendments | Pending RPC |
| Codex | `item/fileChange/requestApproval` | File approval decision, with proposed changes shown | Pending RPC |
| Codex | `item/permissions/requestApproval` | Requested permission subset and turn/session scope | Pending RPC |
| Codex | `execCommandApproval`, `applyPatchApproval` | Legacy decision spelling | Pending RPC |
| Codex | `mcpServer/elicitation/request` | MCP action and typed content | Pending RPC |
| Claude Code | `AskUserQuestion`, `ExitPlanMode` | Per-run `PreToolUse` hook, selected answers or plan decision | Suspended hook |
| Claude Code | `PermissionRequest`, stream `can_use_tool` | Explicit allow/deny and original tool input | Hook or stream control request |
| Claude Code | `Elicitation` | MCP action/content through a hook | Suspended hook |
| Grok | `_x.ai/ask_user_question`, `x.ai/ask_user_question` | `accepted` answers or `cancelled` | Pending ACP request |
| Grok | `_x.ai/exit_plan_mode`, `x.ai/exit_plan_mode` | `approved` or `abandoned` | Pending ACP request |
| Grok | `_x.ai/mcp/elicit`, `x.ai/mcp/elicit` | MCP content with Grok's `outcome` spelling | Pending ACP request |
| Grok | `session/request_permission` | Offered ACP option id or cancellation | Current runner retains automatic execution permissions |
| Antigravity | Native archive `ask_question` call; stream step is `unknown` | Explicit user message continuing the same conversation | Durable until explicit answer/cancel/decline |
| Antigravity | Archived `ask_permission`, `ask_custom_permission`, unsupported questionnaire | Cancel/decline instruction only; no native grant/revocation | Durable message question |

Ordinary execution policies remain configured by the runners. A native question,
plan decision or elicitation is a separate interaction, not permission to execute.
Unrecognized JSON-RPC methods receive a method-not-found error, not an approval.
Authentication token refresh, attestation generation, time requests and arbitrary
dynamic tool execution are not user-question protocols.

## Form shapes and explicit limits

Native questionnaires preserve multiple questions, single/multiple selection,
option descriptions and previews, custom text, and Codex private input. The
async Codex wire format supplies titles and optional string options, without
field ids; Rota assigns stable indices inside the original message id.

MCP `form`, `openai/form` and `openaiForm` use the shared field adapter.
Rota does not opt in to unrestricted OpenAI form schemas; it recognizes these
wire aliases if delivered and checks that their fields are representable. Supported
fields are strings, booleans, numbers, integers, string enums (including titled
`oneOf`, legacy `enumNames`) and arrays of enums (including titled `anyOf`).
Required fields and numeric/length/item bounds are validated; defaults never
stand in for consent. Unanswered optional fields are omitted rather than becoming
false or an empty string. Password/write-only string inputs use private entry.
URL requests show a link and wait for an explicit completion, decline or cancel;
a local test does not authenticate to a real service.

`openai/userVerification` requires device proof Rota cannot generate. The app
shows the request and offers cancel/decline, directing the user to the provider's
app. Extended forms requiring nested objects, references or unsupported root
schemas likewise have a visible refusal path instead of silently returning
strings or an empty object. These paths are deliberately not advertised as
successful device verification or full support for arbitrary JSON Schema.

Asynchronous questions stay in history outside the session retention limit.
The app does not retain a dead RPC callback for them. A pending blocking request
is shown before an earlier async question, because steering an answer cannot
replace its RPC reply. Switching to that request preserves the earlier form draft. Failed continuation leaves
them pending, and a second question is not cleared by answering the first.
Native Terminal replies are unstructured and cannot automatically prove which
persisted async decision was answered; answer the form in Rota for a recorded decision.

## Verification

`QuestionCoverageTests`, `AgentQuestionTests`, `SchedulerTests`, `StorageTests`
and `JSONRPCPeerTests` exercise adapters, refusal paths, scheduler state,
restart, retention, cancellation, replay deduplication and late RPC replies.
The runner seam test sends an actual `item/completed` notification through
`CodexDaemonRun` and verifies that its metadata reaches `RunEvents`.

Opt-in live checks spend vendor quota and create native sessions:

```sh
ROTA_LIVE_QUESTIONS=1 swift test --filter LiveQuestionTests
```

The live suite checks each installed agent's native questionnaire and its reply,
Claude/Grok multiple selection,
Codex's asynchronous message and a later answer in the same thread, and walks
all interaction methods in the installed Codex JSON schema. Interactive Claude
also needs `ROTA_INTERACTIVE_TEST_DIR` set to an already trusted test workspace.
Tests never create trust grants or change the agents' own configuration.

Live questionnaire checks do not cover every vendor approval, real MCP server,
URL login or device-verification flow. Those variants have deterministic wire
and lifecycle coverage, with the unsupported paths explicitly marked above.
`scripts/ui-check.sh --questions-only` renders finished async choice/text forms,
the device-verification refusal surface, and mixed async/blocking requests in
both appearances at 820 x 520 pt,
measures their window and element bounds and never starts an agent. The full
script includes the async form too. A full-script attempt on 2026-10-19 stopped
at its cold menu-panel window lookup before reaching the question checks; a
separate cold-panel probe did show the panel. The focused question check passed,
including typing an async draft, injecting a blocking request through the real
control socket, canceling it and verifying that the draft returns unchanged.
With `ROTA_UI_QUESTION_HARNESS=antigravity`, the focused check also exercises
multiple selection and the permission-refusal surface. A separate check using
the same fixtures, the development panel hook and the
actual Open Rota button through Accessibility rendered all question states in
both appearances. The standard launcher also reproduced an empty window tree
with an idle app after signing. Reopening without environment flags did not
reliably resolve it, and a fresh-signed panel launch also failed once. No app
launch fix is claimed from these checks; the successful rendered check used the
already built bundle, and the cold-launch test limitation remains open.

Verification on 2026-10-19: the native question round trips passed for
Claude Code, Codex and Grok, including interactive Claude, Claude/Grok multiple selection and an
async Codex answer in a later turn. The installed Codex interaction-schema walk
passed. Regression live harness tests passed with only the separately exercised
interactive-mode configuration test skipped. Protocol tests cover the other
approval and elicitation families; real URL login and device proof were not
performed. Mutation checks rejected dropping async metadata, clearing pending
questions at completion, inventing optional values and losing blocking priority.

Owned Codex test threads should be deleted through the daemon that owns them,
over `app-server proxy` and the existing WebSocket/JSON-RPC transport. A second
independent stdio server can report an active writer even after a test turn has
finished; deleting through the owning daemon succeeded. Do not stop a shared
daemon that still hosts other sessions.

## Antigravity question coverage

Antigravity questionnaires use a durable message bridge. The installed CLI
emits the questionnaire's stream step as `unknown`, without its arguments.
`AntigravityQuestionArchive` incrementally reads completed native
`PLANNER_RESPONSE.tool_calls` metadata from the same conversation's archive;
`args.questions` contains a JSON-encoded array. It ignores prose and reasoning.
Single and multiple selection, multiple questions, custom text and empty-option
text fields become the shared Rota form. Stable conversation/step/call ids
deduplicate native row revisions. Resume starts beyond the old archive;
partial rows wait for their newline, and unreadable/truncated sources report
that question sync paused and mark the run failed rather than silently claiming
no questions exist, even if the model process returned success.
An incomplete final archive row is also an error once the native process exits.

The headless native tool returns `User Skipped` even while stdin remains open.
Rota does not pretend to answer that suspended tool. Its form stays pending
after the turn finishes; an explicit answer/cancel/decline continues the same
conversation with a user message. A live test through the real Scheduler
verified two forms, multiple selection and a new custom answer, which the
agent repeated on the next turn. It also verified that answered native calls
did not reappear. `AntigravityQuestionTests` covers the wire adapter, partial
and duplicate records, continuation, corrupt sources and the runner-to-host seam.

The runner's `--dangerously-skip-permissions` execution policy remains in
effect. Archived `ask_permission` and `ask_custom_permission` calls offer only
cancel/decline messages and explain that Rota cannot grant or revoke native
permissions here. This is an unsupported approval surface, not a blocking
permission gate. Unknown question shapes use the same visible refusal path.
The custom permission tool's argument/response contract and an MCP elicitation
bridge remain unverified. See [the runner's implementation and verification limits](architecture.md#antigravity-cli).

A no-generation protocol check on 2026-10-19 sent `control_request` and
`control_response` separately to the installed CLI in a disposable workspace.
Both returned exit 2 and an `ERROR` result stating that the input event is not
supported, with zero turns and zero usage. This matches the
[headless protocol reference](https://www.antigravity.google/docs/cli/headless/#unsupported-messages).
Thus a Claude-style response on stdin is not an available answer path. The
[official hooks reference](https://www.antigravity.google/docs/hooks) has a
different camelCase gating contract, not a documented native questionnaire
answer override. Rota does not install hooks or modify the agent's configuration
to provide its archive/message bridge.

## Sources

- [Codex app-server requests and approvals](https://learn.chatgpt.com/docs/app-server).
  The installed `generate-json-schema --experimental` also exposes async
  `agentMessage.questions`, form aliases and device verification.
- [Claude Code hooks](https://code.claude.com/docs/en/hooks), plus installed
  `claude --help` for stream input and permission hosting.
- Grok's installed user guide, sections 03 (question, elicitation and permission
  cards), 15 (ACP), 19 (plan approval) and 26 (configuration). The wire adapters
  retain both documented extension-prefix spellings.
- [MCP elicitation specification](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation).
