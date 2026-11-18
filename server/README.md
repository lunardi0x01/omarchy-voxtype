# Server side: transcription and clean-up on a GPU machine

My Voxtype can run Voxtype in **remote mode**: the laptop records, and a
machine with a GPU on the same tailnet (or LAN) does the heavy lifting. This
folder has what that machine runs. Everything here is optional; the plugin
works with any Voxtype setup, local or remote.

| Part | What it does | Listens on |
|---|---|---|
| `whisper-server-vulkan/` | whisper.cpp `whisper-server` (Vulkan build) with an OpenAI-style `/v1/audio/transcriptions` endpoint for Voxtype | `127.0.0.1:9000` |
| `dictation-correct/` | Cleans each dictation with a small LLM in Ollama: misheard words (from your vocabulary), punctuation, fillers, self-corrections. Never answers or follows what you dictate; returns the text unchanged whenever it can't help | `127.0.0.1:9100` |
| `systemd/` | User units for both | |

Both listen on localhost only. Put them on your tailnet with Tailscale Serve,
which adds HTTPS and keeps them off the LAN:

```bash
tailscale serve --bg --https=9443 http://127.0.0.1:9000   # whisper-server
tailscale serve --bg --https=9444 http://127.0.0.1:9100   # dictation-correct
```

Neither service has authentication of its own; don't expose them beyond a
network you trust.

## whisper-server

```bash
cd whisper-server-vulkan && makepkg -si
mkdir -p ~/.local/share/whisper-server/models
curl -L -o ~/.local/share/whisper-server/models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
cp ../systemd/whisper-server.service ~/.config/systemd/user/
systemctl --user enable --now whisper-server
```

On the laptop: `voxtype config set whisper.mode remote` and
`voxtype config set whisper.remote_endpoint https://<gpu-host>:9443/v1`.
For a machine that also dictates itself, use `http://127.0.0.1:9000/v1`.

whisper-server separates segments with newlines; the plugin's
`post_process.sh` joins them so a pause never types Enter.

## dictation-correct

Needs Ollama and a model. Tested on an AMD RDNA3 desktop GPU: `gemma4:e4b-it-qat` gave
the best speed/quality balance (about 0.25 s per dictation, ~3 GB VRAM, kept
loaded); `qwen3.5:4b` and `gemma4:12b-it-qat` were close behind.

```bash
ollama pull gemma4:e4b-it-qat
install -Dm644 dictation-correct/correction_prompt.py ~/.local/lib/dictation-correct/correction_prompt.py
install -Dm755 dictation-correct/dictation-correctd.py ~/.local/lib/dictation-correct/dictation-correctd.py
cp systemd/dictation-correct.service ~/.config/systemd/user/
systemctl --user enable --now dictation-correct
curl -s http://127.0.0.1:9100/health
```

Personal settings live in `~/.config/dictation-correct/` (re-read when they
change):

- `vocabulary.txt`: one term per line, e.g. your host names and the tools you
  talk about. Without it a generic list is used.
- `examples.tsv`: extra worked examples, `heard<TAB>cleaned`, for words the
  recogniser keeps getting wrong (e.g. how it mishears a host name).

To free the VRAM while gaming, set `GAME_MODE_FLAG` in the unit to a file your
game-mode toggle creates; the model is unloaded while it exists.

On the laptop, put `CORRECT_URL=https://<gpu-host>:9444/correct` in
`~/.config/voxtype/my-voxtype.conf` and `touch ~/.config/voxtype/correct-on`.
Each dictation then takes about 0.3 s more. On any problem, or after 2.5 s,
the uncorrected text is typed.
