# UI suites

UI verification runs in macOS in Lume, driven through CUA.
The suite now refuses a physical Mac before preparation by default. Run it
inside the guest after transferring sources and the required toolchain. It does
not provision the VM or transfer build products automatically. To transfer
prepared inputs, copy `Rota.app`, `driver` and `prepared.json` together, plus the
matching sources, then pass `--artifacts <directory>` in the guest. Preparation
checks the original source, bundle and driver hashes, verifies the signature,
copies the inputs into its own temporary folder and seals guest paths. Ordinary
prepared manifests bind absolute repository paths and cannot be reused unchanged
in another guest. In a fresh guest, run `git init` over the transferred sources
(preparation hashes `git ls-files`), compile `scripts/ui-driver.swift` there, and
write `prepared.json` with `ui_preparation.fingerprint` over the guest repository,
bundle and driver before `ui-suite.py --artifacts`.
`--host` is reserved for explicitly agreed host diagnostics.
Guest execution suppresses the keyboard and mouse notice.

Select a guest display mode whose visible work area contains the window sizes
and origin used by `capture-screenshots.sh` and `ui-driver.swift`. A larger Lume
display configuration can add modes without selecting one in macOS. Verify the
active mode after the configuring process exits: `CGDisplaySetDisplayMode`
lasts only for that process; `CGCompleteDisplayConfiguration` with `forSession`
keeps the mode for the guest login session. Keep transferred inputs and evidence
archived on the host before restarting the guest; its temporary directory can
be cleared at boot.

Run the surfaces reached by a change with one verified development bundle and AX driver:

```bash
task_ui_output="$(mktemp -d /tmp/rota-ui-results.XXXXXX)"
python3 scripts/ui-suite.py --modes filters questions --out "$task_ui_output"
```

Choose an output folder for the current session. Captures, per-phase logs and
`timings.json` stay there for review. Preparation has its own timing entry.
The suite builds once, checks the bundle's code signature, copies it into a
task-owned temporary folder and compiles the driver once. It unregisters and
removes that prepared copy when it finishes, on failure too. The installed Rota
and another checkout's development app are never stopped. A running development
app or another capture's notice blocks a new suite.

`ui_preparation.py` seals the checkout's sources, package inputs, icon/catalog
assets and scripts, plus every file and symlink in the copied bundle and the
driver. Before and after each phase, it verifies those hashes and the development
bundle identifier. Each worker also validates the manifest before exporting,
clearing or restoring development defaults. A changed input aborts the suite;
there is no unverified skip-build switch. This is reuse within one invocation,
not a persistent cache across source or toolchain changes.

## Actions and renders

The filters and questions modes separate behavioral checks from the remaining
render variants. The action pass also supplies the reference captures, so it
does not need a second light-theme rendering pass at the same scale.

| Surface | Actions and reference captures | Render variants |
| --- | --- | --- |
| Filters | Light, 100%, category union, removal, reset and keyboard routes | Light at 150%, dark at 100% and 150% |
| Questions | Light, choice, multiple selection, custom text, draft isolation, blocking priority and explicit send | Dark, the same captured form states with minimal setup |

Question text captures retain their enlarged-scale check in both appearances.
Render passes use the shipping app and real controls to reach each state. They
retain required transition waits, window-size assertions and the layout gate on
every capture. The full keyboard, draft and explicit-send walkthrough lives in
the action pass. Render variants keep state and visibility guards for trustworthy
captures; setup is not proof that the full interaction passed in every appearance.

On macOS 26, SwiftUI can expose an open menu outside its button's AX subtree.
The driver allows 30 seconds for an AX reply in a loaded VM. A timed-out press
still fails, since repeating it could deliver the action twice.
The driver uses `AXShowMenu` when a control offers it without `AXPress`.
`choose` searches the button and menus attached to its ancestors, then verifies the result.
`press` briefly refetches a missing or replaced AX element during a redraw; other
action failures still stop immediately.
`set` refetches a field after focusing it and retries transient AX errors for
this idempotent assignment. A failed RPC also reads the value back before retrying.
Value waits retry a temporarily absent AX element during a form transition;
only a successful value read can satisfy the wait, including an expected empty value.
`focused` checks the focused element and its ancestors. Keyboard focus moved into the
multi-line message field reports an editor without the field's identifier, so prove
that move by typing (`key z`, then the field's value) rather than with `focused composer`.
Toolbar placement uses the measured sidebar width from the toolbar's origin;
the floating sidebar's AX outline can have an independent inset origin.
An `AXSheet` is a separate window boundary: it may extend past its presenter.
The layout gate checks its frame against the screen and its controls against
the sheet and their own containers.
Floating split-view groups, scroll containers and list rows/cells can report two
points of border overdraw at 150% on Tahoe. Only structural roles receive that
allowance; text, buttons and fields retain the one-point containment tolerance.

Set `ROTA_UI_QUESTION_HARNESS=antigravity` when checking its single/multiple-choice
forms and permission fallback. The existing default remains Codex verification
and choice/text forms. `--question-harnesses codex antigravity` includes both
fixture families in one invocation, sharing the same prepared bundle and driver.

Other modes reuse the same prepared bundle and driver and execute their existing
checks. Supported names are listed by `python3 scripts/ui-suite.py --help`.
`full` runs the full synthetic UI traversal. `live` additionally spends Codex
quota, just as `scripts/ui-check.sh --live` does; opt in explicitly.

The full traversal keeps its synthetic Shell session running until terminal
attachment and the running-state capture pass, then signals it to finish.
Cleanup stops these owned Shell fixtures if the traversal fails earlier.

Standalone `scripts/ui-check.sh --filters-only` and `--questions-only` still run
their complete original appearance matrix and build their own inputs. The suite
passes `--prepared`, `--phase`, `--appearance` and, for filters, `--scale` to select
its checked matrix. Use the suite entry point for a release touching several
surfaces, rather than assembling those internal options by hand.

On failure, inspect that phase's log and its `failures/` evidence before another
run. The suite stops immediately. Keep images containing imported routine names
or real agent configuration outside the repository.

Local panel checks need uninterrupted application focus: switching to another app
closes the menu bar panel. A saved panel image does not prove that a later AX
button check or click succeeded. Inspect the failure's full-screen capture and
AX tree to distinguish a dismissed panel from a missing control.
