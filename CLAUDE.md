# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```bash
# Release build (default)
make build

# Deploy + restart launchd service
make deploy

# Build + deploy + restart
make update

# Run tests
make test

# Clean build artifacts
make clean

# Front-end debugging
make run          # build + foreground serve
```

**Swift 6.3.2 required** — Swift 6.4 snapshot (2026-06-15) crashes on `-O` with MLXAudioTTS. The Makefile uses `TOOLCHAINS=swift-6.3.2-RELEASE`.

## Project Structure

```
Sources/iVox/          — main executable target
  EntryPoint.swift     — @main, ArgumentParser subcommands
  Commands/            — ServeCommand, SpeakCommand, WeChatCommand, etc.
  Daemon/Daemon.swift  — actor-based daemon: init → run → cleanup loop
  TTS/                 — TTSEngine (mlx-audio-swift stream synthesis)
  Audio/               — AudioPlayer, PlaybackQueue, MediaController, MediaHTTPServer
  SpeechInput/         — macOS speech recognition, Cmd-key tap via CGEvent
  WeChat/              — WeChat ilink HTTP client + long-poll platform
  Network/             — SocketServer (Unix domain socket for IPC)
  Utilities/           — Version, logging helpers
  Resources/           — hook.sh, assets, default voices

Sources/iVoxKit/       — shared library (no MLX dependency)
  Config.swift         — JSON config model
  Logger.swift         — Log.{info,debug,warn,error}
  TextCleaner.swift    — Markdown + noise filtering for TTS
  TextSplitter.swift   — chunk text for streaming

Sources/iVoxTests/     — tests (depend on iVoxKit only)

docs/                  — architecture.md, api.md, CHANGELOG.md, hook-chain.md, compiler-bugs.md
scripts/               — runtime.sh, download-models.sh, install-*.sh
```

## Architecture

Actor-based daemon managed by launchd (`com.user.ivox`):

```
Claude Code/Codex  →  hook.sh  →  Unix Socket  →  Daemon
                                                          ├─ PlaybackQueue (actor)
                                                          │   ├─ TTSEngine (mlx-audio-swift)
                                                          │   └─ AudioPlayer (AVAudioEngine)
                                                          ├─ WeChatPlatform (actor, long-poll)
                                                          ├─ SpeechInputService (Cmd-key tap + ASR)
                                                          └─ MediaHTTPServer (port 8888, Web UI)
```

Key patterns:
- **Swift 6 strict concurrency**: All services are `actor` types. Cross-actor calls use `await`. `@Sendable` closures must capture value-copied `let` bindings (not `var` from actor context).
- **Daemon lifecycle**: `init` loads config/preferences → `run()` starts all services in parallel → `cleanup()` tears down on SIGINT/SIGTERM.
- **WeChat long-poll**: `GetUpdatesResp.ret` is `Int?` (API omits `ret` on empty responses). Manual `withThrowingTaskGroup` timeout races the URL request against a `Task.sleep` timer (URLSession idle timeout doesn't fire on long-poll connections with TCP keep-alives).
- **TTS pipeline**: Qwen3-TTS via `mlx-audio-swift` with streaming `AVAudioEngine` playback. Text is preprocessed by `TextCleaner` (strip Markdown noise, URLs, paths, ANSI codes).
- **Config**: JSON at `~/.config/ivox/config.json`. All runtime files under `~/.config/ivox/`.
- **Logging**: `~/.config/ivox/daemon.log` (stdout/stderr from launchd). Use `Log.{info,debug,warn,error}`.

## Key Known Issues

### Compiler crash on Swift 6.4 snapshot
`swift-frontend` crashes with stack overflow in `performSILProcessing()` when building MLXAudioTTS with `-O`/`-Osize`. Workaround: use Swift 6.3.2 stable toolchain. See `docs/compiler-bugs.md`.

### Code signing invalidates TCC on rebuild
Ad-hoc signature changes each build → TCC permissions (Microphone, Accessibility) lost. `make deploy` re-signs automatically. After deploy, re-enable permissions in System Settings if needed.

## Deployment

```bash
make update       # build → sign → copy to ~/.local/bin/ivox → restart launchd
```

The binary at `~/.local/bin/ivox` is what `launchd` and hook scripts invoke. Project dir can be deleted after deploy.

## Testing

```bash
make test
# Or directly:
TOOLCHAINS=swift-6.3.2-RELEASE swift test
```

Tests only cover `iVoxKit` (no MLX dependency, fast). Tests live in `Sources/iVoxTests/`.

## Versioning

```bash
make version V=v1.2.0    # updates Version.swift, commits, tags
```

Version defined in `Sources/iVox/Utilities/Version.swift`.
