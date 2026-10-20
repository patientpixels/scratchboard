# Scratchboard

Lean, keyboard-first clipboard manager for macOS, forked from Maccy. Plan and work items live in GitHub issues (patientpixels/scratchboard); `docs/plan-v0.1.md` has the v0.1 spec.

## Testing

The user works on this Mac while tests run. Keep test runs out of their way.

- `scripts/test unit`: the default; safe to run any time. It skips everything listed in the E2E plan and runs at background priority. Narrow it with `-only-testing:ScratchboardTests/<Class>` while iterating.
- `scripts/test e2e`: disruptive. It overwrites the system clipboard (`ClipboardTests`), uses the real Keychain (may prompt), runs the on-device model, and drives the app UI (`ScratchboardUITests`). **Only run it after telling the user and getting their go-ahead.**
- Launching the app (e.g. with `--fake-llm`) or any test that opens the real panel or sends keystrokes counts as E2E.
- New tests that touch shared system state go into `E2E.xctestplan` (and the skip list in `Unit.xctestplan`). Prefer making them safe instead: inject a uniquely named `NSPasteboard`, an in-memory store or a fake provider.
- Don't run several builds or test runs in parallel; one at a time.

## Project notes

- New source files go under `Scratchboard/Chat/` or `ScratchboardTests/Chat/` (synchronized folders, no `project.pbxproj` edits). Files elsewhere need a project entry.
- Swift 6, app target default actor isolation is MainActor; mark background-safe types `nonisolated`.
- Wording: "clipboard" in anything users see, "pasteboard" in code when it means `NSPasteboard` mechanics.
