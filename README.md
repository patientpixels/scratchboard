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
ollama pull <model>
```

Pick a model with tool support: around 9B parameters suits a 16 GB Mac; with more memory, try larger or mixture-of-experts models. Then choose it in Settings → AI.

Or use any OpenAI-compatible API (OpenAI, OpenRouter, LM Studio, Anthropic's compatibility endpoint): pick "OpenAI-compatible API" in Settings → AI and enter the base URL, model and API key. The key is stored in your Keychain.

## Credits

Built on [Maccy](https://github.com/p0deje/Maccy) by Alex Rodionov and its contributors. Upstream fixes are pulled via the `upstream` remote.
