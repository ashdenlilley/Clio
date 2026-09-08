# Intentional-quit verification

Use the shared `ClioShutdownDiagnostics` scheme in a dedicated Xcode Cloud
workflow. Add a macOS Test action, **Required to Pass**, with retries disabled
and no Archive action. This is a diagnostic workflow, not a release workflow;
it does not need release credentials. The scheme enables Address Sanitizer.

1. Run `diagnostics/quit-baseline` to characterize the unmodified editor teardown.
2. Run `fix/quit-lifecycle` with the same Xcode/macOS environment.
3. Inspect the result bundle, sanitizer output, and app diagnostics. A launch
   failure or skipped test is not evidence that quit is fixed. A sandboxed
   runner may lack access to host crash reports; tests attach that limitation
   and continue checking quit/persistence. Inspect Cloud crash and sanitizer
   artifacts separately: a green test in this mode is not proof of no crash.
   If the baseline does not reproduce, repeat the
   user's exact interaction sequence before drawing conclusions.
4. Require successful keyboard Quit, menu Quit after the final window closes,
   and fullscreen/multiwindow Quit. The tests reuse isolated storage, quit
   without an explicit Save, and verify the final text after relaunch.
5. Check for delayed crash reports after the run as well. The test's short
   report-publication grace period cannot rule out every delayed OS report.
6. Run the normal test suite on the candidate, including save-failure and
   teardown tests. Confirm a failed save still cancels termination.
7. Only after verification, merge the candidate and create the next version
   tag through the existing Cloud packaging workflow. Do not retag an existing
   release. Smoke-test intentional quit from the downloaded notarized DMG.

The candidate disconnects editor callbacks before SwiftUI removal, invalidates
queued restoration against detached surfaces, and retains live editor text
views until process exit after the save gate succeeds. This is a targeted
lifetime mitigation, not yet a proven diagnosis of AppKit's internal callback.
It does not disable drag-and-drop, bypass saves, or suppress crash reporting.

An active-background-save and failed-save quit scenario still requires explicit
verification; ordinary UI typing does not prove the background-write path ran.

## Recurrence in 0.1.7 (build 8)

A user-supplied report from 8 September 2026 confirms a main-thread
`EXC_BAD_ACCESS / SIGSEGV` on macOS 26.6.2, with `objc_msgSend` called from
`-[NSTextView _requestUpdateOfDragTypeRegistration]`'s deferred block. The
remaining frames are the main run loop. This establishes that the shipped
lifetime mitigation has not resolved the reported shutdown crash. It does not
identify the freed object, establish whether the quit save gate ran, or show an
MCP networking fault. Keep the original report and identifying metadata outside
the repository.

The existing teardown unit test retains the text view throughout its deferred
wait, so it cannot detect use after destruction. The added
`WritingWorkspaceTests.testRemovedEditorSurvivesDeferredAppKitCallbacksWithoutRetainingView`
repeatedly configures, detaches, and releases a window/editor graph before
allowing the main run loop to process deferred callbacks. This is a diagnostic
regression probe, pending Cloud execution, not a production fix or a claim that
the crash has been reproduced. Run it with Address Sanitizer and inspect the
allocation/free stacks if it fails. A pass still requires the user's exact quit
sequence to be reproduced against the signed app.
