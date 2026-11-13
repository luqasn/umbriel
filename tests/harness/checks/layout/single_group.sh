#!/usr/bin/env bash
# harness: config-watch=true
# A single-group workspace holds every window in one tab group filling the layout area. Enabling it on a live
# multi-column workspace collapses both columns into the group showing the window that had focus; a second client
# then shares the first's box as a hidden tab, and clicking its bar slot switches which one shows.
set -euo pipefail

readonly BTN_LEFT=272
readonly OUTPUT_W=1280
readonly OUTPUT_H=720
readonly BORDER=2
readonly GAP=8
readonly BAR=24
readonly POINTER="${UMBRIEL_POINTER_CLIENT:-./build-debug/tests/pointer-client}"

pointer() {
  "$POINTER" "$OUTPUT_W" "$OUTPUT_H" "$@"
}

spawn_client() {
  foot --title="$1" sh -c 'sleep 120' > /dev/null 2>&1 &
}

wait_for_windows() {
  local expected=$1 count=
  for _ in $(seq 60); do
    count=$("$UMBRIEL" windows --json | jq 'length')
    [[ $count == "$expected" ]] && return 0
    sleep 0.1
  done
  echo "expected $expected window(s), got $count"
  return 1
}

# Waits until both clients are tabs of one box, `$1` being the only shown and active one.
wait_for_one_group() {
  local shown=$1 windows=
  for _ in $(seq 50); do
    windows=$("$UMBRIEL" windows --json)
    if jq -e --arg shown "$shown" '
      length == 2
      and (map(select(.tabbed)) | length) == 2
      and (map(select(.tab_hidden)) | length) == 1
      and (map(select(.title == $shown and (.tab_hidden | not) and .active and .focused)) | length) == 1
      and (map([.x, .y, .w, .h]) | unique | length) == 1
      and (map(.tab_index) | sort) == [0, 1]
    ' <<< "$windows" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "expected '$shown' to be the shown tab of one full-area group: $windows"
  return 1
}

wait_for_focus() {
  local title=$1 windows=
  for _ in $(seq 50); do
    windows=$("$UMBRIEL" windows --json)
    if jq -e --arg title "$title" 'any(.[]; .title == $title and .focused)' <<< "$windows" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "expected '$title' to have focus: $windows"
  return 1
}

# The centre of tab slot `$1` among `$2` equal slots, as in the tab bar checks: tab_gap is 0 here.
slot_center() {
  local index=$1 count=$2 windows
  windows=$("$UMBRIEL" windows --json)
  jq -r --argjson index "$index" --argjson count "$count" --argjson border "$BORDER" --argjson gap "$GAP" \
    --argjson bar "$BAR" '
    map(select(.tabbed and (.tab_hidden | not)))[0]
    | (.x - $border) as $left | (.w + 2 * $border) as $width
    | "\($left + ($width * (2 * $index + 1) / (2 * $count) | floor)) \(.y - $border - $gap - ($bar / 2 | floor))"
  ' <<< "$windows"
}

# Two equal columns before the option is enabled, so the collapse has an order to preserve.
cat >> "$UMBRIEL_CONFIG" <<'EOF'

[layout.scrolling]
default_extent_fraction = 0.5
EOF
"$UMBRIEL" msg config-reload > /dev/null

spawn_client group-a
wait_for_windows 1
spawn_client group-b
wait_for_windows 2
"$UMBRIEL" settle

# The workspace starts as two ordinary columns. Focus the left one, so the reload has a window to keep.
if ! "$UMBRIEL" windows --json | jq -e '
  length == 2
  and (map(select(.tabbed)) | length) == 0
  and (map([.x, .y, .w, .h]) | unique | length) == 2
' > /dev/null; then
  echo "expected two separate columns before the option is enabled: $("$UMBRIEL" windows --json)"
  exit 1
fi
"$UMBRIEL" msg window-focus-left > /dev/null
wait_for_focus group-a

# The watcher notices this write; no config-reload command is sent.
cat >> "$UMBRIEL_CONFIG" <<'EOF'

[layout.tabs]
single_group = true

[appearance.tab_bar]
tab_gap = 0
EOF

wait_for_one_group group-a

if [[ $("$UMBRIEL" workspaces --json | jq -r '.[] | select(.active) | .layout') != scrolling ]]; then
  echo "expected the single-group workspace to keep the scrolling layout: $("$UMBRIEL" workspaces --json)"
  exit 1
fi

before=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')

read -r x y <<< "$(slot_center 1 2)"
pointer move "$x" "$y" click "$BTN_LEFT"
"$UMBRIEL" settle
wait_for_one_group group-b

after=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
if [[ $before != "$after" ]]; then
  echo "expected the group box to stay put, had $before, now $after"
  exit 1
fi

echo "a reload collapsed two columns into one full-area group showing the previously focused window; a bar slot switched tabs"
