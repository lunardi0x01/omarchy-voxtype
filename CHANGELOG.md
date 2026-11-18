# Changelog

## 0.1.0 (2026-11-18)

First public version.

- Bar icon and keyboard-driven panel: Home, Vocabulary, History, Stats and
  Settings. Settings with fixed values open an inline list; config writes and
  the Voxtype restart share one queue, and restarts clear systemd's
  start-rate counter first.
- `post_process.sh`: joins whisper-server's segment lines, drops sound tags,
  optional clean-up through `server/dictation-correct`, history in Voxtype's
  recommended `history.tsv` format.
- `shortcuts.lua`: Escape cancels a recording; optional hold-to-talk key.
- Settings: press Enter after typing (off / always / when you say "submit").
- Indicators: Edge glow (focused window's left, right and bottom edges,
  moving with the voice) and Pill, as Voxtype OSD style packages.
- `server/`: whisper-server Vulkan package recipe, the `dictation-correct`
  clean-up service (small LLM via Ollama, worked-example prompt, guard
  checks, optional game-mode unloading, no text logging), systemd units.
- Tests: Model.js unit tests, hook tests, panel smoke test, QML lint, CI.
