#!/usr/bin/env bash
# A single-group workspace holds every window in one tab group filling the layout area: a second client shares the
# first's box and is reported as a hidden tab, clicking a bar slot switches which one shows, and the directional window
# actions focus, reorder, and swap its tabs instead of leaving the group.
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
      and (map(select(.title == $shown and (.tab_hidden | not) and .active)) | length) == 1
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

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[layout.tabs]
single_group = true

[appearance.tab_bar]
tab_gap = 0
EOF
"$UMBRIEL" msg config-reload > /dev/null

spawn_client group-a
wait_for_windows 1
spawn_client group-b
wait_for_windows 2
"$UMBRIEL" settle

if [[ $("$UMBRIEL" workspaces --json | jq -r '.[] | select(.active) | .layout') != scrolling ]]; then
  echo "expected the single-group workspace to keep the scrolling layout: $("$UMBRIEL" workspaces --json)"
  exit 1
fi
wait_for_one_group group-b

before=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')

read -r x y <<< "$(slot_center 0 2)"
pointer move "$x" "$y" click "$BTN_LEFT"
"$UMBRIEL" settle
wait_for_one_group group-a

after=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
if [[ $before != "$after" ]]; then
  echo "expected the group box to stay put, had $before, now $after"
  exit 1
fi

# The usual focus keys walk the tabs, and a move reorders the shown one without leaving the group.
"$UMBRIEL" msg window-focus-right > /dev/null
"$UMBRIEL" settle
wait_for_one_group group-b

"$UMBRIEL" msg window-move-left > /dev/null
"$UMBRIEL" settle
wait_for_one_group group-b
order=$("$UMBRIEL" windows --json | jq -c 'sort_by(.tab_index) | map(.title)')
if [[ $order != '["group-b","group-a"]' ]]; then
  echo "expected the move to put group-b first, got $order"
  exit 1
fi

# Swapping exchanges the shown tab with its neighbour and keeps the box.
"$UMBRIEL" msg window-swap-right > /dev/null
"$UMBRIEL" settle
wait_for_one_group group-b
order=$("$UMBRIEL" windows --json | jq -c 'sort_by(.tab_index) | map(.title)')
if [[ $order != '["group-a","group-b"]' ]]; then
  echo "expected the swap to put group-a first, got $order"
  exit 1
fi

swapped=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
if [[ $before != "$swapped" ]]; then
  echo "expected the group box to stay put through a swap, had $before, now $swapped"
  exit 1
fi

# A column move has one column to act on, so it changes neither the order nor the box.
"$UMBRIEL" msg column-move-left > /dev/null
"$UMBRIEL" settle
column_order=$("$UMBRIEL" windows --json | jq -c 'sort_by(.tab_index) | map(.title)')
column_box=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
if [[ $column_order != '["group-a","group-b"]' || $column_box != "$before" ]]; then
  echo "expected a column move to leave the group alone, got $column_order in $column_box"
  exit 1
fi

echo "single-group workspace held both clients in one full-area tab group, switched by slot, and walked, reordered, and swapped its tabs"
