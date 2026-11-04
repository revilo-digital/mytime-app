#!/bin/zsh
# Tells MyTime what an AI coding tool is doing in a folder, so the time can be suggested on the timesheet.
#
#   activity-hook.sh [source]                         a beat: the tool is working here now (for tool hooks)
#   activity-hook.sh log "<1-3 words>" [minutes] [source]
#                                                     a label for the work, plus an estimate for time
#                                                     MyTime didn't measure
#
# source: claude (default), cursor, … The folder is $CLAUDE_PROJECT_DIR, else the working folder, resolved to its
# repository's main checkout so worktrees count towards the same project. Beats print nothing and never fail,
# so they can't get in the tool's way; `log` confirms what it logged.

json_escape() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  s=${s//$'\t'/ }
  print -r -- "$s"
}

project_folder() {
  local dir=${CLAUDE_PROJECT_DIR:-$PWD} common top
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [[ $common == */.git ]]; then
    print -r -- "${common%/.git}"
  elif top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    print -r -- "$top"
  else
    print -r -- "$dir"
  fi
}

append() {
  local inbox="$HOME/Library/Application Support/MyTime/Activity"
  mkdir -p "$inbox" && print -r -- "$1" >> "$inbox/inbox.jsonl"
}

if [[ $1 == log ]]; then
  label=$2 minutes=${3:-0} source=${4:-claude}
  [[ $minutes == <->(|.<->) ]] || { print -u2 "minutes must be a number, e.g. 45"; exit 1; }
  if [[ -z ${label// /} && $minutes == 0 ]]; then
    print -u2 'usage: activity-hook.sh log "<1-3 words>" [minutes] [source]'
    exit 1
  fi
  folder=$(project_folder)
  append "{\"type\":\"note\",\"at\":$(date +%s),\"folder\":\"$(json_escape "$folder")\",\"source\":\"$(json_escape "$source")\",\"note\":\"$(json_escape "$label")\",\"minutes\":$minutes}" \
    || { print -u2 "Couldn't write to MyTime's inbox"; exit 1; }
  words=(${=label})
  (( ${#words} > 3 )) && print "Note: MyTime keeps the first 3 words: ${words[1,3]}"
  suffix=""
  [[ $minutes != 0 ]] && suffix=" (estimate ${minutes}m)"
  print -r -- "Logged to MyTime for ${folder:t}: \"$label\"$suffix"
  exit 0
fi

{
  cat >/dev/null 2>&1 # The hook's JSON on stdin isn't needed.
  append "{\"at\":$(date +%s),\"folder\":\"$(json_escape "$(project_folder)")\",\"source\":\"$(json_escape "${1:-claude}")\"}"
} >/dev/null 2>&1
exit 0
