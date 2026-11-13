#!/usr/bin/env bash
# harness: outputs=2
# harness: config-watch=true
# A single-group workspace holds every window in one tab group filling the layout area. Enabling it on a live
# multi-column workspace collapses both columns into the group showing the window that had focus; a second client
# then shares the first's box as a hidden tab, clicking its bar slot switches which one shows, and the directional
# window actions focus, reorder, and swap its tabs without leaving the group. Maximize toggles state without moving
# the group while maximize-to-edges still fills the output, switching the workspace to another layout and back shows
# the previously focused tab, and dragging a slot reorders without splitting the group. Mod+dragging the group has no
# strip position or width to give it.
set -euo pipefail

readonly BTN_LEFT=272
readonly OUTPUT_W=2560
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

# Waits until every client is a tab of one box, `$1` being the only shown, active, and focused one.
wait_for_one_group() {
  local shown=$1 expected=$2 windows=
  for _ in $(seq 50); do
    windows=$("$UMBRIEL" windows --json)
    if jq -e --arg shown "$shown" --argjson count "$expected" '
      length == $count
      and (map(select(.tabbed)) | length) == $count
      and (map(select(.tab_hidden)) | length) == $count - 1
      and (map(select(.title == $shown and (.tab_hidden | not) and .active and .focused)) | length) == 1
      and (map([.x, .y, .w, .h]) | unique | length) == 1
      and (map(.column) | unique | length) == 1
      and (map(.tab_index) | sort) == [range(0; $count)]
    ' <<< "$windows" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "expected '$shown' to be the shown tab of one full-area group of $expected: $windows"
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

# The shown tab's bar span: its leading edge, its length, and the height through the middle of the bar.
bar_span() {
  "$UMBRIEL" windows --json | jq -r --argjson border "$BORDER" --argjson gap "$GAP" --argjson bar "$BAR" '
    map(select(.tabbed and (.tab_hidden | not)))[0]
    | "\(.x - $border) \(.w + 2 * $border) \(.y - $border - $gap - ($bar / 2 | floor))"
  '
}

# Every window's box together with the tab state the bar actions must leave alone.
state() {
  "$UMBRIEL" windows --json \
    | jq -c 'sort_by(.title) | map({title, x, y, w, h, layout, tabbed, tab_index, tab_hidden, active, maximized})'
}

# Two equal columns before the option is enabled, so the collapse has an order to preserve. The pair stays on
# HEADLESS-1, leaving HEADLESS-2 for the first-configure arrival.
cat >> "$UMBRIEL_CONFIG" <<'CONFIG'
[layout.scrolling]
default_extent_fraction = 0.5

[[window_rule]]
match.title = "^group-[ab]$"
default_output = "HEADLESS-1"
CONFIG
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
# The pair sits on HEADLESS-1, which need not be the output the session booted focused.
if [[ $("$UMBRIEL" outputs --json | jq -r '.[] | select(.focused) | .name') != HEADLESS-1 ]]; then
  "$UMBRIEL" msg output-focus-next > /dev/null
  "$UMBRIEL" settle
fi
"$UMBRIEL" msg window-focus-left > /dev/null
wait_for_focus group-a

# The watcher notices this write; no config-reload command is sent.
cat >> "$UMBRIEL_CONFIG" <<'CONFIG'

[layout.tabs]
single_group = true

[appearance.tab_bar]
tab_gap = 0

CONFIG

wait_for_one_group group-a 2

if [[ $("$UMBRIEL" workspaces --json | jq -r '.[] | select(.output == "HEADLESS-1" and .active) | .layout') != scrolling ]]; then
  echo "expected the single-group workspace to keep the scrolling layout: $("$UMBRIEL" workspaces --json)"
  exit 1
fi

before=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')

read -r x y <<< "$(slot_center 1 2)"
pointer move "$x" "$y" click "$BTN_LEFT"
"$UMBRIEL" settle
wait_for_one_group group-b 2

after=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
if [[ $before != "$after" ]]; then
  echo "expected the group box to stay put, had $before, now $after"
  exit 1
fi

# Maximize toggles its state even though the group already fills the layout area. Maximize-to-edges still fills the
# output, and restoring leaves the group box alone.
"$UMBRIEL" msg window-toggle-maximize > /dev/null
"$UMBRIEL" settle
if ! "$UMBRIEL" windows --json | jq -e --arg title group-b '
  any(.[]; .title == $title and .maximized and (.maximized_to_edges | not))
  and (map([.x, .y, .w, .h]) | unique | length) == 1
' > /dev/null || [[ $("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique') != "$before" ]]; then
  echo "window-toggle-maximize did not keep the group's box while turning its state on: $("$UMBRIEL" windows --json)"
  exit 1
fi
"$UMBRIEL" msg window-toggle-maximize > /dev/null
"$UMBRIEL" settle
if "$UMBRIEL" windows --json | jq -e 'any(.[]; .title == "group-b" and .maximized)' > /dev/null; then
  echo "window-toggle-maximize did not turn its state back off: $("$UMBRIEL" windows --json)"
  exit 1
fi
"$UMBRIEL" msg window-toggle-maximize-to-edges > /dev/null
"$UMBRIEL" settle
if ! "$UMBRIEL" windows --json | jq -e 'any(.[]; .title == "group-b" and .maximized_to_edges)' > /dev/null; then
  echo "window-toggle-maximize-to-edges did not maximize to the output: $("$UMBRIEL" windows --json)"
  exit 1
fi
"$UMBRIEL" msg window-toggle-maximize-to-edges > /dev/null
"$UMBRIEL" settle
if [[ $("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique') != "$before" ]]; then
  echo "restoring maximize-to-edges did not restore the group box: $("$UMBRIEL" windows --json)"
  exit 1
fi

# Return to the first tab before walking, reordering, and swapping.
read -r x y <<< "$(slot_center 0 2)"
pointer move "$x" "$y" click "$BTN_LEFT"
"$UMBRIEL" settle
wait_for_one_group group-a 2

# The usual focus keys walk the tabs, and a move reorders the shown one without leaving the group.
"$UMBRIEL" msg window-focus-right > /dev/null
wait_for_one_group group-b 2

"$UMBRIEL" msg window-move-left > /dev/null
wait_for_one_group group-b 2
order=$("$UMBRIEL" windows --json | jq -c 'sort_by(.tab_index) | map(.title)')
if [[ $order != '["group-b","group-a"]' ]]; then
  echo "expected the move to put group-b first, got $order"
  exit 1
fi

# Swapping exchanges the shown tab with its neighbour and keeps the box.
"$UMBRIEL" msg window-swap-right > /dev/null
wait_for_one_group group-b 2
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

# The bar still hides and shows, giving its space to the tabs and taking it back.
before_bar=$(state)
shown="$("$UMBRIEL" windows --json | jq -r '.[] | select(.tab_hidden | not) | .title')"
bar_height=$("$UMBRIEL" windows --json | jq -r --arg title "$shown" '.[] | select(.title == $title) | .h')
"$UMBRIEL" msg column-hide-tab-bar > /dev/null
"$UMBRIEL" settle
hidden_bar_height=$("$UMBRIEL" windows --json | jq -r --arg title "$shown" '.[] | select(.title == $title) | .h')
if (( hidden_bar_height != bar_height + BAR + GAP )); then
  echo "expected hiding the bar to add $((BAR + GAP))px, got $bar_height then $hidden_bar_height"
  exit 1
fi
"$UMBRIEL" msg column-show-tab-bar > /dev/null
"$UMBRIEL" settle
if [[ $(state) != "$before_bar" ]]; then
  echo "expected showing the bar to restore the group: $(state)"
  exit 1
fi

# Dragging the first slot to the trailing half of the bar puts it after the other tab instead of tearing the group
# apart, and leaves the group's box alone.
group_box=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
read -r left width bar_y <<< "$(bar_span)"
start_x=$((left + width / 4))
end_x=$((left + width * 3 / 4))
pointer move "$start_x" "$bar_y" press "$BTN_LEFT" move "$((start_x + 60))" "$bar_y" pause 200 \
  move "$end_x" "$bar_y" pause 200 release "$BTN_LEFT"
for _ in $(seq 50); do
  order=$(jq -c 'sort_by(.tab_index) | map(.title)' <<< "$("$UMBRIEL" windows --json)")
  [[ $order == '["group-b","group-a"]' ]] && break
  sleep 0.1
done

windows=$("$UMBRIEL" windows --json)
if ! jq -e '
  ((map(select(.title | startswith("group-"))) | sort_by(.tab_index) | map(.title)) == ["group-b", "group-a"])
    and (map(.tabbed) | all)
    and (map([.x, .y, .w, .h]) | unique | length) == 1
    and (map(.column) | unique | length) == 1
' <<< "$windows" > /dev/null; then
  echo "dragging a bar slot did not reorder the tabs in place: $windows"
  exit 1
fi
reordered=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
if [[ $group_box != "$reordered" ]]; then
  echo "reordering a tab moved the group box, had $group_box, now $reordered"
  exit 1
fi

# Mod+dragging the group inside its own workspace has nowhere to move or resize it.
order=$("$UMBRIEL" windows --json | jq -c 'map(select(.title | startswith("group-")) | [.title, .tab_index, .tab_hidden]) | sort_by(.[1])')
box=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
read -r x y <<< "$("$UMBRIEL" windows --json | jq -r 'map(select(.tab_hidden | not))[0] | "\(.x + (.w / 2 | floor)) \(.y + (.h / 2 | floor))"')"
pointer mod logo move "$x" "$y" press "$BTN_LEFT" move "$((x + 80))" "$y" pause 200 \
  move "$((x + 120))" "$((y + 60))" pause 200 release "$BTN_LEFT" mod none
"$UMBRIEL" settle

windows=$("$UMBRIEL" windows --json)
if [[ $(jq -c 'map([.x, .y, .w, .h]) | unique' <<< "$windows") != "$box" ]] \
  || [[ $(jq -c 'map(select(.title | startswith("group-")) | [.title, .tab_index, .tab_hidden]) | sort_by(.[1])' <<< "$windows") != "$order" ]] \
  || ! jq -e '(map(.tabbed) | all) and (map(.column) | unique | length) == 1' <<< "$windows" > /dev/null; then
  echo "Mod+dragging the group moved or resized it: $windows"
  exit 1
fi

echo "a reload collapsed two columns into one full-area group showing the previously focused window; a bar slot switched tabs, maximize and maximize-to-edges round-tripped, directional window actions walked, reordered, and swapped the tabs, a dragged slot joined the group, and a Mod+drag left it alone"
