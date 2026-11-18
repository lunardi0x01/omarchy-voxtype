const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8");
const M = {};
vm.createContext(M);
vm.runInContext(source, M, { filename: "Model.js" });

test("server origin and label", () => {
  assert.equal(M.originOf("https://gpu-box.example.ts.net:9443/v1"), "https://gpu-box.example.ts.net:9443");
  assert.equal(M.hostLabel("https://gpu-box.example.ts.net:9443/v1"), "gpu-box");
  assert.equal(M.hostLabel("http://127.0.0.1:9000/v1"), "this computer");
  assert.equal(M.hostLabel("http://192.0.2.10:9000/v1"), "192.0.2.10");
  assert.equal(M.originOf("not a url"), "");
});

test("terms round-trip through initial_prompt", () => {
  const terms = M.parseTerms("Omarchy, Hyprland, Arch Linux, omarchy.");
  assert.deepEqual(Array.from(terms), ["Omarchy", "Hyprland", "Arch Linux"]);
  assert.equal(M.formatTerms(["Omarchy", " Hyprland ", "a,b", ""]), "Omarchy, Hyprland, a b.");
  assert.equal(M.formatTerms([]), "");
  assert.equal(M.hasTerm(["Vulkan"], "vulkan"), true);
});

test("chords", () => {
  assert.equal(M.cleanChord("super+f10"), "SUPER + f10");
  assert.equal(M.cleanChord("SUPER + SHIFT + D"), "SUPER + SHIFT + D");
  assert.equal(M.cleanChord("F9"), "F9");
  assert.equal(M.cleanChord(""), "");
  assert.equal(M.cleanChord("SUPER + ; rm -rf"), null);
  assert.equal(M.cleanChord("FOO + F9"), null);
});

test("config output with replacements", () => {
  const text = JSON.stringify({ "whisper.language": "en", "osd.enabled": true }) + "\n\n"
    + JSON.stringify({ keys: [], replacements: { "a Marche": "Omarchy", amachi: "Omarchy" } });
  const parsed = M.parseConfigOutput(text);
  assert.equal(parsed.config["whisper.language"], "en");
  assert.equal(parsed.replacements["a Marche"], "Omarchy");
  const list = M.replacementList(parsed.replacements);
  assert.equal(list[0].heard, "a Marche");
  assert.equal(M.parseConfigOutput("garbage"), null);
});

test("pretty-printed config with nested objects", () => {
  const config = {
    "audio.pause_media": true,
    profiles: { cortana: { vocabulary: { terms: [], note: "a } brace" } } },
    "text.replacements": { "a Marche": "Omarchy" },
    "whisper.language": "en",
  };
  const text = JSON.stringify(config, null, 2) + "\n\n"
    + JSON.stringify({ replacements: { "a Marche": "Omarchy" } }, null, 2);
  const parsed = M.parseConfigOutput(text);
  assert.equal(parsed.config["whisper.language"], "en");
  assert.equal(parsed.config["audio.pause_media"], true);
  assert.equal(parsed.replacements["a Marche"], "Omarchy");
});

test("sources skip monitors", () => {
  const json = JSON.stringify([
    { name: "out.monitor", description: "Monitor of X", properties: { "device.class": "monitor" } },
    { name: "alsa_input.cam", description: "USB Webcam Analog Stereo", properties: { "device.class": "sound" } },
  ]);
  const parsed = M.parseSources("alsa_input.cam\n" + json);
  assert.equal(parsed.defaultSource, "alsa_input.cam");
  assert.equal(parsed.sources.length, 1);
  assert.equal(M.sourceLabel(parsed.sources, "alsa_input.cam"), "USB Webcam");
});

test("history, timings and stats", () => {
  const now = Date.parse("2026-11-18T20:00:00");
  const hist = M.parseHistory(
    "2026-11-10T10:00:00+00:00\tOld words here\n"
    + "2026-11-18T09:00:00+00:00\tOne two three four\n"
    + "bad line\n"
    + "2026-11-18T19:00:00+00:00\tFive six\n");
  assert.equal(hist.length, 3);
  assert.equal(hist[0].text, "Five six");
  const timings = M.parseTimings("2026-11-18T08:59:00+00:00\t3.00\t150\n2026-11-18T18:59:00+00:00\t1.50\t140\n");
  const s = M.computeStats(hist, timings, now);
  assert.equal(s.wordsAll, 9);
  assert.equal(s.wordsToday, 6);
  assert.equal(s.dictations, 3);
  assert.equal(s.wpm, 80);           // 6 words over 4.5 s
  assert.equal(s.medianLatencyMs, 145);
});

test("probe and status lines", () => {
  assert.deepEqual(Object.assign({}, M.parseProbe(0, "200 0.042")), { reachable: true, ms: 42 });
  assert.equal(M.parseProbe(7, "000 0.001").reachable, false);
  assert.equal(M.parseProbe(0, "502 0.1").reachable, false);
  assert.equal(M.parseStatusLine('{"alt":"recording","class":"recording"}'), "recording");
  assert.equal(M.parseStatusLine("{oops"), "");
  assert.equal(M.parseStatusLine("idle"), "idle");
});

test("cycle and formatting", () => {
  assert.equal(M.cycle([1, 2, 3], 3, 1), 1);
  assert.equal(M.cycle([1, 2, 3], 1, -1), 3);
  assert.equal(M.cycle(["a", "b"], "z", 1), "a");
  assert.equal(M.formatElapsed(67), "1:07");
  assert.equal(M.formatCount(1234567), "1,234,567");
  assert.equal(M.boundedDiagnostic("\x1b[31mError: boom\x1b[0m\n", "x"), "boom");
});
