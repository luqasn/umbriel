#!/usr/bin/env bash
# harness: outputs=2
# harness: config-watch=true
# A single-group workspace holds every window in one tab group filling the layout area. Enabling it on a live
# multi-column workspace collapses both columns into the group showing the window that had focus; a second client
# then shares the first's box as a hidden tab, clicking its bar slot switches which one shows, dragging a slot
# reorders without splitting the group, and a window dragged in from another workspace joins at the new-tab position.
# Window rules and actions that need several columns or a resizable one are inert: the named-column order rule is
# ignored and the inapplicable actions leave the full-area box and tab state untouched, while the bar actions still
# apply.
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

# Every window's box together with the tab state the inert actions must leave alone.
state() {
  "$UMBRIEL" windows --json \
    | jq -c 'sort_by(.title) | map({title, x, y, w, h, layout, tabbed, tab_index, tab_hidden, active})'
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

# Two equal columns before the option is enabled, so the collapse has an order to preserve. The pair stays on
# HEADLESS-1, leaving HEADLESS-2 for the window dragged in from another workspace.
cat >> "$UMBRIEL_CONFIG" <<'EOF'

[layout.scrolling]
default_extent_fraction = 0.5

[[window_rule]]
match.title = "^group-[ab]$"
default_output = "HEADLESS-1"
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
# The pair sits on HEADLESS-1, which need not be the output the session booted focused.
if [[ $("$UMBRIEL" outputs --json | jq -r '.[] | select(.focused) | .name') != HEADLESS-1 ]]; then
  "$UMBRIEL" msg output-focus-next > /dev/null
  "$UMBRIEL" settle
fi
"$UMBRIEL" msg window-focus-left > /dev/null
wait_for_focus group-a

# The watcher notices this write; no config-reload command is sent.
cat >> "$UMBRIEL_CONFIG" <<'EOF'

[layout.tabs]
single_group = true

[appearance.tab_bar]
tab_gap = 0

[[window_rule]]
match.title = "^group-c$"
default_output = "HEADLESS-2"
EOF

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

# Re-open the pair under rules that a single-group workspace must ignore. The rules are only read when a window maps,
# so the collapsed pair is closed first; the single group and the option stay in place across the respawn.
"$UMBRIEL" msg window-close > /dev/null
wait_for_windows 1
"$UMBRIEL" settle
"$UMBRIEL" msg window-close > /dev/null
wait_for_windows 0
"$UMBRIEL" settle

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[[window_rule]]
match.title = "^group-a$"
default_scrolling_column = "test-column"
default_scrolling_column_order = 20
default_scrolling_extent = 0.5
default_column_display = "normal"

[[window_rule]]
match.title = "^group-b$"
default_scrolling_column = "test-column"
default_scrolling_column_order = 10
default_scrolling_extent_px = 400
EOF
"$UMBRIEL" msg config-reload > /dev/null

spawn_client group-a
wait_for_windows 1
spawn_client group-b
wait_for_windows 2
"$UMBRIEL" settle

if [[ $("$UMBRIEL" workspaces --json | jq -r '.[] | select(.output == "HEADLESS-1" and .active) | .layout') != scrolling ]]; then
  echo "expected the single-group workspace to keep the scrolling layout: $("$UMBRIEL" workspaces --json)"
  exit 1
fi
wait_for_one_group group-b 2

# The named-column order rule is ignored: the second arrival stays last instead of sorting before the first.
if [[ $("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-a") | .tab_index') != 0 ]]; then
  echo "expected the named-column order rule to leave group-a first: $("$UMBRIEL" windows --json)"
  exit 1
fi

before=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')

read -r x y <<< "$(slot_center 0 2)"
pointer move "$x" "$y" click "$BTN_LEFT"
"$UMBRIEL" settle
wait_for_one_group group-a 2

after=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
if [[ $before != "$after" ]]; then
  echo "expected the group box to stay put, had $before, now $after"
  exit 1
fi

# Actions that need several columns, a resizable one, or a stacking split leave the group untouched.
before=$(state)
actions=(
  window-consume-left
  window-consume-right
  window-consume-or-expel-left
  window-consume-or-expel-right
  window-consume-from-left
  window-consume-from-right
  layout-toggle-split
  column-move-left
  column-move-right
  column-move-to-first
  column-move-to-last
  layout-scroll-left
  layout-scroll-right
  layout-scroll-up
  layout-scroll-down
  "window-set-primary-extent 0.5"
  "window-modify-primary-extent 0.1"
  window-cycle-primary-extent
  window-cycle-primary-extent-back
  "window-set-secondary-extent 0.5"
  "window-modify-secondary-extent 0.1"
  window-cycle-secondary-extent
  window-cycle-secondary-extent-back
  "column-set-display normal"
  column-toggle-tabbed
)
for action in "${actions[@]}"; do
  read -r -a args <<< "$action"
  "$UMBRIEL" msg "${args[@]}" > /dev/null
  "$UMBRIEL" settle
  if [[ $(state) != "$before" ]]; then
    echo "expected $action to leave the single group unchanged: $(state)"
    exit 1
  fi
done

# The bar still hides and shows, giving its space to the tabs and taking it back.
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
if [[ $(state) != "$before" ]]; then
  echo "expected showing the bar to restore the group: $(state)"
  exit 1
fi

# Dragging the first slot to the trailing half of the bar puts it after the other tab instead of tearing the group
# apart, and leaves the group's box alone.
group_box=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
read -r left width bar_y <<< "$(bar_span)"
start_x=$((left + width / 4))
end_x=$((left + width * 3 / 4))
pointer move "$start_x" "$bar_y" press "$BTN_LEFT" move "$((start_x + 60))" "$bar_y" \
  move "$end_x" "$bar_y" release "$BTN_LEFT"
"$UMBRIEL" settle

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

# A window opened on another workspace's single-group workspace, dragged in with Mod, becomes a tab of the same group
# instead of opening a column beside it, and leaves its own workspace.
spawn_client group-c
wait_for_windows 3
"$UMBRIEL" settle
for _ in $(seq 50); do
  [[ $("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-c") | .tabbed') == true ]] && break
  sleep 0.1
done
read -r start_x start_y <<< "$(
  "$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-c") | "\(.x + (.w / 2 | floor)) \(.y + (.h / 2 | floor))"'
)"
read -r group_x group_y group_h <<< "$(
  "$UMBRIEL" windows --json | jq -r '[.[] | select(.workspace | startswith("HEADLESS-1"))][0] | "\(.x) \(.y) \(.h)"'
)"
drop_x=$((group_x + 640))
# The top eighth is off the bar and outside the group's middle, so only the new-tab position can hold the drop.
drop_y=$((group_y + group_h / 8))
pointer mod logo move "$start_x" "$start_y" press "$BTN_LEFT" move "$((start_x - 80))" "$start_y" \
  move "$drop_x" "$drop_y" release "$BTN_LEFT" mod none
"$UMBRIEL" settle
wait_for_one_group group-c 3

windows=$("$UMBRIEL" windows --json)
if ! jq -e '.[] | select(.title == "group-c") | .tab_index == 2' <<< "$windows" > /dev/null; then
  echo "the window dragged in from another workspace did not join at the new-tab position: $windows"
  exit 1
fi
if [[ $("$UMBRIEL" windows --json | jq '[.[] | select(.workspace | startswith("HEADLESS-2"))] | length') != 0 ]]; then
  echo "the window dragged off its workspace stayed behind: $("$UMBRIEL" windows --json)"
  exit 1
fi

# Mod+dragging the group inside its own workspace has nowhere to move or resize it.
order=$("$UMBRIEL" windows --json | jq -c 'map(select(.title | startswith("group-")) | [.title, .tab_index, .tab_hidden]) | sort_by(.[1])')
box=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
read -r x y <<< "$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-c") | "\(.x + (.w / 2 | floor)) \(.y + (.h / 2 | floor))"')"
pointer mod logo move "$x" "$y" press "$BTN_LEFT" move "$((x + 80))" "$y" \
  move "$((x + 120))" "$((y + 60))" release "$BTN_LEFT" mod none
"$UMBRIEL" settle

windows=$("$UMBRIEL" windows --json)
if [[ $(jq -c 'map([.x, .y, .w, .h]) | unique' <<< "$windows") != "$box" ]] \
  || [[ $(jq -c 'map(select(.title | startswith("group-")) | [.title, .tab_index, .tab_hidden]) | sort_by(.[1])' <<< "$windows") != "$order" ]] \
  || ! jq -e '(map(.tabbed) | all) and (map(.column) | unique | length) == 1' <<< "$windows" > /dev/null; then
  echo "Mod+dragging the group moved or resized it: $windows"
  exit 1
fi

echo "a reload collapsed two columns into one full-area group showing the previously focused window; a dragged-in window and a dragged slot joined it, and inapplicable rules and actions were ignored"
