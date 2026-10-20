# Scratchboard

A lean, keyboard-first clipboard manager for macOS. Every copied item is a scratch buffer: pull it up, rework it in a quick chat with an LLM, paste it anywhere.

Free and open source (MIT).

> Early days. Scratchboard is a fork of [Maccy](https://github.com/p0deje/Maccy) and currently behaves like it.

## Build

Open `Scratchboard.xcodeproj` in Xcode 26+, pick your signing team, and run the `Scratchboard` scheme. Requires macOS 14+.

## AI setup

Chats need a model. The default is [Ollama](https://ollama.com), running locally:

```sh
brew install ollama
brew services start ollama
ollama pull qwen3.5:9b-nvfp4
```

Then choose the model in Settings → AI. Recommended models, measured with `scripts/eval` on an M5 Max (October 2026):

| Mac memory | Model | Size | Notes |
|---|---|---|---|
| 8 GB | `qwen3.5:4b-nvfp4` | 4 GB | Fast, handles everyday edits |
| 16 GB | `qwen3.5:9b-nvfp4` | 7 GB | Good default |
| 32 GB+ | `gpt-oss:20b` | 13 GB | Most reliable, a little slower |
| 32 GB+ | `qwen3.5:35b-a3b-nvfp4` | 21 GB | Fastest; sometimes asks instead of guessing on vague prompts |

Run `scripts/eval <model>...` to compare models on your own Mac.

Or use any OpenAI-compatible API (OpenAI, OpenRouter, LM Studio, Anthropic's compatibility endpoint): pick "OpenAI-compatible API" in Settings → AI and enter the base URL, model and API key. The key is stored in your Keychain.

## Credits

Built on [Maccy](https://github.com/p0deje/Maccy) by Alex Rodionov and its contributors. Upstream fixes are pulled via the `upstream` remote.
