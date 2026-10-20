# Scratchboard v0.1: chat on a clip

Lean, keyboard-first. A chat loop with an LLM that operates on a versioned artefact. Text clips only.

## Interaction

The chat takes over the whole panel:

```
┌──────────────────────────────┐
│ v3 ▸ (editable artefact)     │
│ - point one                  │
│ - point two                  │
├──────────────────────────────┤
│ you: make it a list          │
│ ai:  done            → v3    │
├──────────────────────────────┤
│ > shorter_            ⌘↩     │
└──────────────────────────────┘
```

| Key | Effect |
|---|---|
| Tab (text clip highlighted in list) | Open chat, prompt focused. The clip becomes v1. |
| ↩ | Newline, always |
| ⌘↩ | Send prompt |
| Esc / ⌘C | Close the dialog (cancels any running turn). Current version is already on the pasteboard. |
| ⌘Z / ⇧⌘Z | Step back / forward through versions; transcript stays intact |
| Tab / ⇧Tab | Prompt → artefact / artefact → prompt (Tab inside the artefact inserts a tab) |

- **Versions** are append-only: v1, v2, … Undo moves a pointer; nothing is discarded. New versions are appended and based on the current one.
- **Auto-copy:** whenever the current version changes, it's written to the pasteboard with the `org.nspasteboard.TransientType` marker, so Scratchboard and other clipboard managers skip it.
- **History:** on close, the current version is saved as one normal history item (unless it's still v1) and linked to the session. The original clip is untouched.
- **Manual edits:** the artefact is editable. An edit becomes a new version, attributed to the user, when focus leaves the artefact or the next prompt is sent.
- **Undo** uses the window's single undo history. Text edits and version changes interleave in the order they happened, so ⌘Z undoes the most recent thing.
- **Transcript:** prompts, assistant messages, and version events (`→ v3`, `user edited → v4`, `undo → v2`). The model gets all of it, so it can refer to discarded versions.
- **Sessions persist by default.** Scratchboard is a history manager, so it keeps the full history of edits. The session (transcript + every version) is stored with the clip it started from. Tab on the original clip or on the saved result reopens the session at that version, and you continue where you left off.
- After reopening, the in-memory undo stack starts empty; ⌘Z then steps back through the stored versions.
- **Resume:** opening the panel after closing a chat goes straight back into that chat, at its current version, as long as nothing else has been copied since the chat's last own write (version auto-copies, the saved final version, copies from inside the chat). Afterwards the panel opens on the list as usual.
- **Copies from inside the chat** (⌘C with a selection in the artefact, prompt or transcript) are transient, so they stay out of history. A selection copied last stays on the pasteboard when the dialog closes.
- **Private mode:** Settings → "Keep edit history" (default on). When it's off, sessions live only in memory and are discarded once something else is copied after closing (until then the chat can be resumed). Only the final version goes to history, as usual.
- Sessions follow the clip lifecycle: deleting a clip, clearing history, or the history size limit removes a session once no clip links to it. Pinned clips keep theirs.

## Agent loop

Each turn, the model gets a system prompt, the transcript with every version labelled, and the current version number. It replies in chat and acts on the artefact through tools:

- `write_artefact(text)` creates a new version
- `restore_version(n)` makes vN current by copying it as a new version, so the history stays linear

The loop runs until the model replies without calling a tool. The model is told to put artefact content only in tool calls, never in chat text, so every version can be pasted as-is. Chat text is sanitized regardless: `<artefact>` blocks and echoed `Request:` / `Current version:` lines are removed.

Both providers support tool calling: FoundationModels via its `Tool` protocol, and OpenAI-compatible endpoints via the `tools` parameter. Apple's on-device model has a small context window, so it gets the current version plus the last few turns instead of the full history.

## Providers

- **Apple on-device** (FoundationModels, macOS 26+, `#available`). Default when available.
- **OpenAI-compatible** `/v1/chat/completions` with streaming and tools: base URL, model, API key (stored in Keychain). Covers OpenAI, OpenRouter, Ollama, LM Studio, and Anthropic's compatibility endpoint.

Nothing is sent before ⌘↩. The prompt placeholder names the provider and model.

## Code

New code goes in `Scratchboard/Chat/`; edits to Maccy's code stay small so upstream merges remain easy.

- SwiftData models alongside `HistoryItem`: `EditSession` (versions, transcript entries, current-version index) with an optional relationship from `HistoryItem`.
- Introduce `VersionedSchema` + `SchemaMigrationPlan` in `Storage`: `SchemaV1` = Maccy's current `HistoryItem`/`HistoryItemContent`, `SchemaV2` = + `EditSession`, with a lightweight stage V1→V2. Existing Maccy-shaped stores open as V1 and migrate; future changes get explicit stages.
- `ChatSession`: runtime controller over an `EditSession` (turn task, undo registration, transient copy). Uses an in-memory model when "Keep edit history" is off.
- `ArtefactTools`: tool definitions + execution against `ChatSession`
- `LLMProvider` protocol → `AppleProvider`, `OpenAICompatibleProvider`
- `ChatView`: artefact editor (NSTextView-backed), transcript, prompt
- `Keychain`: small SecItem wrapper
- `AISettingsPane`: provider, base URL, model, key (English only)

Touch points in existing code: `KeyChord` (`.startChat`), `KeyHandlingView` (stay out of the way while chatting, like `isEditingItem`), `ContentView` (swap list ↔ chat, focus), `AppState` (`chat`, `startChat()`, `endChat()`, settings pane), `Clipboard` (transient copy).

## Order

1. Versioned schema + migration plan (test: a V1 store migrates to V2 with items intact), `EditSession` model + `ChatSession` (versions, undo, transient copy, persistence and private mode, cleanup with clip lifecycle) with a fake provider, plus unit tests
2. `ChatView` + Tab/⌘↩/Esc/⌘C/⌘Z wiring
3. `OpenAICompatibleProvider` with streaming and tool calls (test the SSE + tool-call parsing)
4. Settings pane + Keychain
5. `AppleProvider`

## Not in v0.1

Images, presets/recipes, auto-paste into the target app, a UI for browsing sessions beyond Tab-to-resume.
