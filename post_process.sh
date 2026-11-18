#!/bin/sh
# Voxtype post-process command (output.post_process.command) for My Voxtype.
#
# 1. Joins whisper-server's segment lines into one line, so a pause in
#    dictation never types Enter.
# 2. Drops Whisper's sound tags: *BEEP*, [BLANK_AUDIO], (MUSIC).
# 3. Squeezes spaces and trims.
# 3b. Optional clean-up by a local model: when ~/.config/voxtype/correct-on
#    exists and CORRECT_URL is set (in ~/.config/voxtype/my-voxtype.conf),
#    the text is sent to the dictation-correct service
#    (server/dictation-correct: a small LLM via Ollama, with guard checks). The service replies with the text unchanged whenever it can't
#    help, and on any network error or after CORRECT_TIMEOUT (2.5 s) the
#    text is used as it is. When the text changed, the original is kept in
#    corrections.tsv next to the history log.
# 4. Appends the result to the history log, unless history is switched off
#    (~/.config/voxtype/history-off exists). The log format is the one
#    Voxtype's own documentation recommends until built-in history ships
#    (upstream #209): `<ISO-8601 time>\t<text>`, one dictation per line,
#    readable only by the user.
# 5. Prints the text for Voxtype to type.

log="${VOXTYPE_HISTORY_FILE:-$HOME/.local/share/voxtype/history.tsv}"
off="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/history-off"
correct_on="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/correct-on"

text=$(tr '\n\t' '  ' \
  | sed -E 's/\*[A-Z][A-Z _-]*\*//g; s/\[[A-Z][A-Z _-]*\]//g; s/\([A-Z][A-Z _-]*\)//g' \
  | tr -s ' ' | sed 's/^ //; s/ $//')

# Machine-specific settings (CORRECT_URL, CORRECT_TIMEOUT) live outside the
# repo; see my-voxtype.conf.example.
conf="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/my-voxtype.conf"
[ -r "$conf" ] && . "$conf"
correct_url="${CORRECT_URL:-}"
if [ -n "$text" ] && [ -e "$correct_on" ] && [ -n "$correct_url" ]; then
  raw=$text
  text=$(printf '%s' "$raw" | curl -s -m "${CORRECT_TIMEOUT:-2.5}" --data-binary @- \
      -H 'Content-Type: text/plain; charset=utf-8' "$correct_url" 2>/dev/null \
    | tr '\n\t' '  ' | tr -s ' ' | sed 's/^ //; s/ $//')
  [ -n "$text" ] || text=$raw
  if [ "$text" != "$raw" ] && [ ! -e "$off" ]; then
    mkdir -p "$(dirname "$log")"
    umask 077
    printf '%s\t%s\t%s\n' "$(date -Iseconds)" "$raw" "$text" >> "$(dirname "$log")/corrections.tsv"
  fi
fi

if [ -n "$text" ] && [ ! -e "$off" ]; then
  mkdir -p "$(dirname "$log")"
  umask 077
  printf '%s\t%s\n' "$(date -Iseconds)" "$text" >> "$log"
fi

printf '%s' "$text"
