# Scratchboard

A lean, keyboard-first clipboard manager for macOS. Every clip is a scratch buffer: pull it up, rework it in a chat with an LLM, paste the result anywhere. Every version is kept.

Free and open source (MIT). Built on [Maccy](https://github.com/p0deje/Maccy).

> **Early days.** There's no signed release yet; build from source (below).

## How it works

1. Copy text as usual. Scratchboard keeps the history.
2. **⇧⌘C** opens the panel. Arrow to a clip, press **Tab**.
3. Tell the assistant what to do ("make this a bullet list", "fix typos", "shorter") and press **⌘↩**. It edits the text and tells you what it changed.
4. Each edit is a new version and lands on your clipboard immediately. **Esc**, then **⌘V** wherever you need it.

| Key | In the chat |
|---|---|
| ⌘↩ | Send |
| ↩ | Newline; in an empty prompt, copy the current version and close |
| ⌘Z / ⇧⌘Z | Step back / forward through versions (the conversation stays) |
| Tab / ⇧Tab | Move between the prompt and the text, which you can edit yourself |
| Esc, ⌘C | Close; the current version is on the clipboard |

**⌘F3** captures text from the screen: select a region, and the recognised text becomes a clip with the chat open on it, so you can fix what was misread ("fix the OCR errors", "make this a table"). The shortcut can be changed in Settings → General; the first capture asks for Screen Recording permission.

Sessions are saved with the clip: open the panel again, press Tab on it and carry on where you left off. Turn off Settings → AI → "Keep edit history" to keep chats in memory only.

## Install

Requires macOS 14+ and Xcode 26+.

```sh
git clone https://github.com/patientpixels/scratchboard.git && cd scratchboard
xcodebuild -scheme Scratchboard -configuration Release -derivedDataPath .build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
open .build/DerivedData/Build/Products/Release/Scratchboard.app
```

Or open `Scratchboard.xcodeproj`, pick your signing team and run the `Scratchboard` scheme. Pasting into other apps directly from the history needs Accessibility permission; the chat only copies.

## AI setup

The chat needs a model. The default is [Ollama](https://ollama.com), running locally, so nothing leaves your Mac:

```sh
brew install ollama
brew services start ollama
ollama pull qwen3.5:9b-nvfp4
```

Then choose the model in Settings → AI. Recommended models, measured with `scripts/eval` on an M5 Max (October 2026):

| Mac memory | Model | Size | Notes |
|---|---|---|---|
| 8 GB | `qwen3.5:4b-nvfp4` | 4 GB | Fast (~3 s per edit), handles everyday edits |
| 16 GB+ | `qwen3.5:9b-nvfp4` | 7 GB | Good default (~5 s per edit) |
| 16 GB+ | `gpt-oss:20b` | 13 GB | Most careful, asks when a request is vague, but ~10 s per edit |

`qwen3.5:35b-a3b` is fast but sometimes claims edits it didn't make, so it isn't recommended. Run `scripts/eval <model>...` to compare models on your own Mac.

Or use any OpenAI-compatible API (OpenAI, OpenRouter, LM Studio, Anthropic's compatibility endpoint): pick "OpenAI-compatible API" in Settings → AI and enter the base URL, model and API key. The key is stored in your Keychain. Nothing is sent until you press ⌘↩.

## Development

- `scripts/test unit`: the safe test suite; runs at background priority and doesn't touch your clipboard.
- `scripts/test e2e`: tests that overwrite the clipboard, use the Keychain and drive the UI.
- `scripts/eval <model>...`: compares models on fixed editing tasks through the real chat loop.
- `scripts/release`: signed, notarized releases; see [docs/releasing.md](docs/releasing.md).

Plans and work items live in [GitHub issues](https://github.com/patientpixels/scratchboard/issues); the v0.1 spec is [docs/plan-v0.1.md](docs/plan-v0.1.md).

## Credits

Built on [Maccy](https://github.com/p0deje/Maccy) by Alex Rodionov and its contributors. Upstream fixes are pulled via the `upstream` remote.
