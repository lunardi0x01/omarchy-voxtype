"use strict";

// Pure helpers for My Voxtype: parsing command output and computing what
// the panel shows. No QML or Quickshell here, so tests/model.test.js can
// run it under Node.

var MAX_OUTPUT = 4194304;
var MAX_HISTORY_SHOWN = 500;

var LANGUAGES = ["en", "auto", "de", "fr", "es", "it", "nl", "pt", "pl"];
var LANGUAGE_NAMES = {
  en: "English", auto: "Detect", de: "German", fr: "French", es: "Spanish",
  it: "Italian", nl: "Dutch", pt: "Portuguese", pl: "Polish"
};
// edge-glow and pill are this plugin's own OSD style packages (osd/).
var INDICATORS = ["edge-glow", "pill", "capsule", "aura", "halo", "shell-dots", "shell-line", "off"];
var INDICATOR_NAMES = {
  "edge-glow": "Edge glow", pill: "Pill", capsule: "Capsule", aura: "Aura", halo: "Halo", "shell-dots": "Shell dots",
  "shell-line": "Shell line", off: "Off", "default": "Default"
};
var MAX_DURATIONS = [30, 60, 120, 300];
var TIMEOUTS = [5, 10, 20, 30];
// When Voxtype presses Enter after typing: never, always, or when the
// dictation ends with the word "submit" (Voxtype removes the word).
var AUTO_SUBMIT = ["off", "always", "say"];
var AUTO_SUBMIT_NAMES = { off: "Off", always: "Always", say: "When I say \u201csubmit\u201d" };

function clip(text, max) {
  return String(text === undefined || text === null ? "" : text).slice(0, max || MAX_OUTPUT);
}

// "https://gpu-box.example.ts.net:9443/v1" -> "https://gpu-box.example.ts.net:9443"
function originOf(endpoint) {
  var m = /^(https?:\/\/[^\/?#\s]+)/i.exec(String(endpoint || "").trim());
  return m ? m[1] : "";
}

// Short name for the server: the first DNS label, or the IP.
function hostLabel(endpoint) {
  var m = /^https?:\/\/(?:[^@\/]*@)?(\[[^\]]+\]|[^:\/?#]+)/i.exec(String(endpoint || "").trim());
  if (!m) return "";
  var host = m[1];
  if (host === "127.0.0.1" || host === "localhost" || host === "[::1]") return "this computer";
  if (/^[0-9.]+$/.test(host) || host.charAt(0) === "[") return host;
  return host.split(".")[0];
}

// initial_prompt "Omarchy, Hyprland, Arch Linux." -> ["Omarchy", "Hyprland", "Arch Linux"]
function parseTerms(prompt) {
  var text = String(prompt || "").trim().replace(/\.$/, "");
  if (text === "") return [];
  var out = [];
  var parts = text.split(",");
  for (var i = 0; i < parts.length; i++) {
    var t = parts[i].trim();
    if (t !== "" && !hasTerm(out, t)) out.push(t);
  }
  return out;
}

function formatTerms(list) {
  var clean = [];
  for (var i = 0; i < (list || []).length; i++) {
    var t = cleanTerm(list[i]);
    if (t !== "" && !hasTerm(clean, t)) clean.push(t);
  }
  return clean.length ? clean.join(", ") + "." : "";
}

// A term can't contain the separator, and stays short.
function cleanTerm(term) {
  return String(term || "").replace(/[,\n\r\t]/g, " ").replace(/\s+/g, " ").trim().replace(/\.$/, "").slice(0, 60);
}

function hasTerm(list, term) {
  var needle = String(term).toLowerCase();
  for (var i = 0; i < (list || []).length; i++)
    if (String(list[i]).toLowerCase() === needle) return true;
  return false;
}

// Replacement phrases: one line, no dots (a dot would split the config key).
function cleanPhrase(text) {
  return String(text || "").replace(/[\n\r\t.]/g, " ").replace(/\s+/g, " ").trim().slice(0, 80);
}

// A Hyprland chord such as "SUPER + F10"; "" clears; null means invalid.
function cleanChord(chord) {
  var text = String(chord || "").trim().replace(/\s*\+\s*/g, " + ").replace(/\s+/g, " ");
  if (text === "") return "";
  if (!/^[A-Za-z0-9_]+( \+ [A-Za-z0-9_]+)*$/.test(text)) return null;
  var parts = text.split(" + ");
  var mods = { SUPER: 1, SHIFT: 1, CTRL: 1, CONTROL: 1, ALT: 1, MOD: 1 };
  for (var i = 0; i < parts.length - 1; i++)
    if (!mods[parts[i].toUpperCase()]) return null;
  for (var j = 0; j < parts.length - 1; j++) parts[j] = parts[j].toUpperCase();
  return parts.join(" + ");
}

// `voxtype config get --json` output, a blank line, then `config schema --json`.
function parseConfigOutput(text) {
  var raw = clip(text);
  var cut = raw.indexOf("}\n");
  if (cut < 0) return null;
  var config, schema;
  try { config = JSON.parse(raw.slice(0, cut + 1)) } catch (e) { return null }
  try { schema = JSON.parse(raw.slice(cut + 1).trim()) } catch (e2) { schema = null }
  if (!config || typeof config !== "object") return null;
  var replacements = {};
  if (schema && schema.replacements && typeof schema.replacements === "object") {
    for (var k in schema.replacements)
      if (Object.prototype.hasOwnProperty.call(schema.replacements, k))
        replacements[k] = String(schema.replacements[k]);
  }
  return { config: config, replacements: replacements };
}

function replacementList(map) {
  var keys = [];
  for (var k in map || {}) if (Object.prototype.hasOwnProperty.call(map, k)) keys.push(k);
  keys.sort(function(a, b) { return a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0 });
  return keys.map(function(k) { return { heard: k, written: String(map[k]) } });
}

// `pactl get-default-source` then `pactl -f json list sources`.
function parseSources(text) {
  var raw = clip(text);
  var nl = raw.indexOf("\n");
  var def = nl >= 0 ? raw.slice(0, nl).trim() : raw.trim();
  var list = [];
  try { list = JSON.parse(nl >= 0 ? raw.slice(nl + 1) : "[]") } catch (e) { list = [] }
  var sources = [];
  for (var i = 0; i < (Array.isArray(list) ? list.length : 0); i++) {
    var s = list[i] || {};
    var props = s.properties || {};
    if (props["device.class"] === "monitor" || /\.monitor$/.test(String(s.name || ""))) continue;
    if (!s.name) continue;
    sources.push({ name: String(s.name), description: String(s.description || s.name) });
  }
  return { defaultSource: def, sources: sources };
}

function sourceLabel(sources, name) {
  for (var i = 0; i < (sources || []).length; i++)
    if (sources[i].name === name) return shortDevice(sources[i].description);
  return name ? shortDevice(name) : "System default";
}

// "USB Webcam Analog Stereo" -> "USB Webcam"
function shortDevice(text) {
  return String(text || "").replace(/\s+(Analog|Digital)\s+(Stereo|Mono|Surround[\s\d.]*)$/i, "").trim();
}

// history.tsv: "<ISO time>\t<text>" per line. Newest first.
function parseHistory(text) {
  var lines = clip(text).split("\n");
  var out = [];
  for (var i = lines.length - 1; i >= 0; i--) {
    var line = lines[i];
    var tab = line.indexOf("\t");
    if (tab <= 0) continue;
    var time = Date.parse(line.slice(0, tab));
    var body = line.slice(tab + 1);
    if (isNaN(time) || body.trim() === "") continue;
    out.push({ line: line, time: time, text: body, words: countWords(body) });
  }
  return out;
}

// timings.tsv: "<ISO time>\t<recording secs>\t<latency ms>".
function parseTimings(text) {
  var lines = clip(text).split("\n");
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split("\t");
    if (f.length < 3) continue;
    var time = Date.parse(f[0]);
    var rec = parseFloat(f[1]);
    var ms = parseInt(f[2], 10);
    if (isNaN(time) || !(rec > 0) || isNaN(ms)) continue;
    out.push({ time: time, recSecs: rec, latencyMs: ms });
  }
  return out;
}

function countWords(text) {
  var m = String(text || "").match(/[^\s]+/g);
  return m ? m.length : 0;
}

function startOfDay(now) {
  var d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

// Monday 00:00 of the current week.
function startOfWeek(now) {
  var d = new Date(startOfDay(now));
  var day = (d.getDay() + 6) % 7;
  d.setDate(d.getDate() - day);
  return d.getTime();
}

function median(values) {
  if (!values.length) return -1;
  var v = values.slice().sort(function(a, b) { return a - b });
  var mid = Math.floor(v.length / 2);
  return v.length % 2 ? v[mid] : Math.round((v[mid - 1] + v[mid]) / 2);
}

function computeStats(history, timings, now) {
  var today = startOfDay(now);
  var week = startOfWeek(now);
  var s = { wordsToday: 0, wordsWeek: 0, wordsAll: 0, dictationsToday: 0, dictations: 0,
    wpm: -1, medianLatencyMs: -1, timed: 0 };
  for (var i = 0; i < (history || []).length; i++) {
    var h = history[i];
    s.wordsAll += h.words;
    s.dictations += 1;
    if (h.time >= week) s.wordsWeek += h.words;
    if (h.time >= today) { s.wordsToday += h.words; s.dictationsToday += 1 }
  }
  // Speaking speed: words over recording time, using only the dictations
  // that have a timing (timings.tsv starts later than history.tsv).
  var t = timings || [];
  if (t.length > 0) {
    var since = t[0].time - 5000;
    var words = 0, secs = 0;
    for (var j = 0; j < (history || []).length; j++)
      if (history[j].time >= since) words += history[j].words;
    for (var k = 0; k < t.length; k++) secs += t[k].recSecs;
    if (secs > 0 && words > 0) s.wpm = Math.round(words / (secs / 60));
    var recent = t.slice(-50).map(function(x) { return x.latencyMs });
    s.medianLatencyMs = median(recent);
    s.timed = t.length;
  }
  return s;
}

// curl -w "%{http_code} %{time_total}" -> { reachable, ms }
function parseProbe(exitCode, text) {
  var m = /^(\d{3})\s+([\d.]+)/.exec(String(text || "").trim());
  if (exitCode !== 0 || !m) return { reachable: false, ms: -1 };
  var code = parseInt(m[1], 10);
  return { reachable: code >= 200 && code < 500, ms: Math.round(parseFloat(m[2]) * 1000) };
}

// One line of `voxtype status --follow --format json`.
function parseStatusLine(line) {
  var text = String(line || "").trim();
  if (text === "") return "";
  try {
    var o = JSON.parse(text);
    var alt = String(o.alt || o["class"] || "");
    if (alt === "idle" || alt === "recording" || alt === "transcribing" || alt === "stopped") return alt;
    return "";
  } catch (e) {
    return /^(idle|recording|transcribing|stopped)$/.test(text) ? text : "";
  }
}

function boundedDiagnostic(text, fallback) {
  var t = String(text || "").replace(/\x1b\[[0-9;]*m/g, "").trim().split("\n").filter(function(l) {
    return l.trim() !== "";
  });
  var last = t.length ? t[t.length - 1] : "";
  last = last.replace(/^Error:\s*/, "");
  return last ? last.slice(0, 200) : fallback;
}

// Next value in a list after `current` (step +1/-1), wrapping; first if absent.
function cycle(list, current, step) {
  if (!list || !list.length) return current;
  var i = -1;
  for (var k = 0; k < list.length; k++) if (String(list[k]) === String(current)) i = k;
  if (i < 0) return list[0];
  var n = list.length;
  return list[((i + (step < 0 ? -1 : 1)) % n + n) % n];
}

function languageName(code) { return LANGUAGE_NAMES[code] || String(code || "English") }
function indicatorName(id) { return INDICATOR_NAMES[id] || String(id) }
function autoSubmitName(mode) { return AUTO_SUBMIT_NAMES[mode] || "Off" }

function formatElapsed(seconds) {
  var total = Math.max(0, Math.floor(seconds));
  var m = Math.floor(total / 60);
  var s = total % 60;
  return m + ":" + (s < 10 ? "0" : "") + s;
}

// "14:05" today, "Yesterday 14:05", "Mon 14:05" this week, else "3 Nov 14:05".
function formatTime(time, now) {
  var d = new Date(time);
  var hh = (d.getHours() < 10 ? "0" : "") + d.getHours();
  var mm = (d.getMinutes() < 10 ? "0" : "") + d.getMinutes();
  var hm = hh + ":" + mm;
  var today = startOfDay(now);
  if (time >= today) return hm;
  if (time >= today - 86400000) return "Yesterday " + hm;
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  if (time >= today - 6 * 86400000) return days[d.getDay()] + " " + hm;
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return d.getDate() + " " + months[d.getMonth()] + " " + hm;
}

function formatCount(n) {
  var v = Math.max(0, Math.round(n || 0));
  return String(v).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function limitHistory(history) {
  return (history || []).slice(0, MAX_HISTORY_SHOWN);
}
