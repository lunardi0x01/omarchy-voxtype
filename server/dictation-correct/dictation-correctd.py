#!/usr/bin/env python3
"""dictation-correctd: the dictation clean-up service (runs on the machine
with Ollama, typically the desktop that also runs whisper-server).

Serves POST /correct on 127.0.0.1; put it on your tailnet or LAN with e.g.
Tailscale Serve. The request body is the transcript as UTF-8 text; the reply
is the cleaned text. Whenever anything goes wrong (model not loaded, Ollama
error, timeout, a failed guard check) it replies with the transcript
unchanged, so a client can always type whatever comes back.

It keeps the model loaded in Ollama permanently. Optionally, when the file
named by GAME_MODE_FLAG exists (e.g. a flag your game-mode toggle creates),
the model is unloaded to free VRAM and loaded again when the file goes away.
Requests never load the model themselves, so dictating mid-game can't pull it
back into VRAM.

Nothing dictated is logged; the journal only gets timings and errors.

Settings (environment):
  DICTATION_LLM_MODEL   default gemma4:e4b-it-qat
  OLLAMA_URL            default http://127.0.0.1:11434
  CORRECT_PORT          default 9100
  CORRECT_TIMEOUT       seconds for the model call, default 2.0
  GAME_MODE_FLAG        path of a file meaning "unload the model"; unset = never
  CORRECT_CONFIG_DIR    default $XDG_CONFIG_HOME/dictation-correct, holding
                        vocabulary.txt  one term per line (default: a generic list)
                        examples.tsv    extra worked examples: heard<TAB>cleaned
"""
import json, os, re, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from correction_prompt import build_system, EXAMPLES, wrap  # noqa: E402

MODEL = os.environ.get("DICTATION_LLM_MODEL", "gemma4:e4b-it-qat")
OLLAMA = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
PORT = int(os.environ.get("CORRECT_PORT", "9100"))
TIMEOUT = float(os.environ.get("CORRECT_TIMEOUT", "2.0"))
FLAG = os.environ.get("GAME_MODE_FLAG", "")
CONFIG_DIR = os.environ.get("CORRECT_CONFIG_DIR") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "dictation-correct")


def read_config():
    """Vocabulary and extra examples, re-read when the files change."""
    vocab, examples = [], []
    try:
        with open(os.path.join(CONFIG_DIR, "vocabulary.txt")) as f:
            vocab = [l.strip() for l in f if l.strip() and not l.startswith("#")]
    except OSError:
        pass
    try:
        with open(os.path.join(CONFIG_DIR, "examples.tsv")) as f:
            for l in f:
                if "\t" in l and not l.startswith("#"):
                    a, b = l.rstrip("\n").split("\t", 1)
                    examples.append((a.strip(), b.strip()))
    except OSError:
        pass
    return build_system(vocab), examples


_config = {"mtime": None, "system": build_system([]), "examples": []}


def config():
    stamp = []
    for name in ("vocabulary.txt", "examples.tsv"):
        try:
            stamp.append(os.path.getmtime(os.path.join(CONFIG_DIR, name)))
        except OSError:
            stamp.append(None)
    if stamp != _config["mtime"]:
        _config["system"], _config["examples"] = read_config()
        _config["mtime"] = stamp
    return _config["system"], _config["examples"]

state = {"loaded": False, "game_mode": False}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def ollama(path, body=None, timeout=5.0):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(OLLAMA + path, data, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def is_loaded():
    try:
        return any(m.get("name") == MODEL for m in ollama("/api/ps", timeout=1.0).get("models", []))
    except Exception:
        return False


def keeper():
    """Keep the model loaded outside Game Mode; unload it in Game Mode."""
    while True:
        game = bool(FLAG) and os.path.exists(FLAG)
        state["game_mode"] = game
        loaded = is_loaded()
        try:
            if game and loaded:
                ollama("/api/generate", {"model": MODEL, "keep_alive": 0}, timeout=10)
                log(f"game mode: unloaded {MODEL}")
                loaded = False
            elif not game and not loaded:
                ollama("/api/generate", {"model": MODEL, "keep_alive": -1}, timeout=120)
                log(f"loaded {MODEL} (kept loaded)")
                loaded = True
        except Exception as e:
            log(f"keeper: {type(e).__name__}: {e}")
        state["loaded"] = loaded
        time.sleep(5)


def messages(text):
    system, extra = config()
    m = [{"role": "system", "content": system}]
    for raw, clean in EXAMPLES + extra:
        m += [{"role": "user", "content": wrap(raw)}, {"role": "assistant", "content": json.dumps({"text": clean})}]
    m.append({"role": "user", "content": wrap(text)})
    return m


def guard_ok(raw, text):
    """Reject answers that look like anything but a cleaned transcript."""
    words_in, words_out = raw.split(), text.split()
    ratio = len(words_out) / max(1, len(words_in))
    if not text:
        return False
    if len(words_in) >= 6 and not 0.6 <= ratio <= 1.4:
        return False
    if re.search(r"[$£€]", text) and not re.search(r"[$£€]|dollar|pound|euro|quid", raw, re.I):
        return False
    if re.match(r"(sure|certainly|of course|here is|here's|i'm sorry|i cannot|i can't help)\b", text, re.I):
        return False
    if "<transcript" in text.lower():
        return False
    return True


def correct(raw):
    if not raw.strip():
        return raw, "empty"
    if state["game_mode"] or not is_loaded():
        return raw, "not-loaded"
    body = {"model": MODEL, "stream": False, "think": False, "keep_alive": -1, "messages": messages(raw),
            "options": {"temperature": 0, "num_predict": max(64, len(raw) // 2 + 40)},
            "format": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}
    try:
        reply = ollama("/api/chat", body, timeout=TIMEOUT)["message"]["content"]
        text = json.loads(reply)["text"].strip()
    except Exception as e:
        return raw, f"error {type(e).__name__}"
    if not guard_ok(raw, text):
        return raw, "guard"
    return text, "ok"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # no access log: it would hold nothing useful
        pass

    def reply(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, json.dumps({"model": MODEL, "loaded": state["loaded"], "game_mode": state["game_mode"]}),
                       "application/json")
        else:
            self.reply(404, "not found\n")

    def do_POST(self):
        if self.path != "/correct":
            self.reply(404, "not found\n")
            return
        n = min(int(self.headers.get("Content-Length") or 0), 65536)
        raw = self.rfile.read(n).decode("utf-8", "replace")
        t = time.time()
        text, how = correct(raw)
        log(f"correct: {how} {(time.time() - t) * 1000:.0f} ms, {len(raw.split())} words")
        self.reply(200, text)


if __name__ == "__main__":
    threading.Thread(target=keeper, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    log(f"dictation-correctd: {MODEL} on 127.0.0.1:{PORT}")
    srv.serve_forever()
