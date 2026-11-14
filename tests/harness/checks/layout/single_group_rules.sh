#!/usr/bin/env bash
# harness: outputs=2
# A single-group workspace ignores the rules that would place or size a column, leaves actions that need several
# columns or a resizable one inert, shows the previously focused tab after a layout-mode round trip, receives a
# window dragged in from another workspace at the new-tab position, and lets a tab leave for another scrolling
# workspace at that workspace's own width instead of its full-width source. A title-bar arrival's first configure
# already equals the group's arranged box.
set -euo pipefail

readonly BTN_LEFT=272
readonly OUTPUT_W=2560
readonly OUTPUT_H=720
readonly POINTER="${UMBRIEL_POINTER_CLIENT:-./build-debug/tests/pointer-client}"
readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"

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

# Every window's box together with the tab state the inert actions must leave alone.
state() {
  "$UMBRIEL" windows --json \
    | jq -c 'sort_by(.title) | map({title, x, y, w, h, layout, tabbed, tab_index, tab_hidden, active})'
}

wait_for_title() {
  local title=$1 query=$2 windows=
  for _ in $(seq 60); do
    windows=$("$UMBRIEL" windows --json)
    if jq -e --arg title "$title" "$query" <<< "$windows" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "expected '$title' to satisfy $query: $windows"
  return 1
}

wait_for_workspace() {
  local title=$1 prefix=$2 windows=
  for _ in $(seq 60); do
    windows=$("$UMBRIEL" windows --json)
    if jq -e --arg title "$title" --arg prefix "$prefix:" '
      any(.[]; .title == $title and (.workspace | startswith($prefix)))
    ' <<< "$windows" > /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "expected '$title' on $prefix: $windows"
  return 1
}

wait_for_layout() {
  local expected=$1 actual=
  for _ in $(seq 60); do
    actual=$("$UMBRIEL" workspaces --json | jq -r '.[] | select(.output == "HEADLESS-1" and .active) | .layout')
    [[ $actual == "$expected" ]] && return 0
    sleep 0.1
  done
  echo "expected HEADLESS-1 to use the $expected layout, got $actual"
  return 1
}

# The option applies only to HEADLESS-1, leaving HEADLESS-2 a normal 0.25-extent scrolling workspace for the
# leaving-tab check. The pair's named-column, extent, and display rules are all read on map and must be ignored.
cat >> "$UMBRIEL_CONFIG" <<'CONFIG'

[layout.scrolling]
default_extent_fraction = 0.5

[output.HEADLESS-1]
position = [0, 0]
layout.scrolling.default_extent_fraction = 0.5

[output.HEADLESS-2]
position = [1280, 0]
layout.scrolling.default_extent_fraction = 0.25

[[workspace]]
index = 1
output = "HEADLESS-1"
layout.mode = "scrolling"
layout.tabs.single_group = true

[[window_rule]]
match.title = "^group-a$"
default_output = "HEADLESS-1"
default_scrolling_column = "test-column"
default_scrolling_column_order = 20
default_scrolling_extent = 0.5
default_column_display = "normal"

[[window_rule]]
match.title = "^group-b$"
default_output = "HEADLESS-1"
default_scrolling_column = "test-column"
default_scrolling_column_order = 10
default_scrolling_extent_px = 400

[[window_rule]]
match.title = "^group-c$"
default_output = "HEADLESS-2"

[[window_rule]]
match.title = "^dest-baseline$"
default_output = "HEADLESS-2"

[[window_rule]]
match.title = "^first-configure$"
default_output = "HEADLESS-1"
title_bar = "forced"
CONFIG
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
# The pair sits on HEADLESS-1, which need not be the output the session booted focused.
if [[ $("$UMBRIEL" outputs --json | jq -r '.[] | select(.focused) | .name') != HEADLESS-1 ]]; then
  "$UMBRIEL" msg output-focus-next > /dev/null
  "$UMBRIEL" settle
  wait_for_one_group group-b 2
fi

# The named-column order rule is ignored: the second arrival stays last instead of sorting before the first.
if [[ $("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-a") | .tab_index') != 0 ]]; then
  echo "expected the named-column order rule to leave group-a first: $("$UMBRIEL" windows --json)"
  exit 1
fi

# Switching away from scrolling and back replays the windows through insertion. The mode-switch route must show the
# window that had focus, exactly as the reload-triggered collapse does, even when it is not the last one replayed.
"$UMBRIEL" msg window-focus-left > /dev/null
wait_for_one_group group-a 2
before_switch=$("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique')
"$UMBRIEL" msg workspace-set-layout dwindle > /dev/null
"$UMBRIEL" settle
wait_for_layout dwindle
"$UMBRIEL" msg workspace-set-layout scrolling > /dev/null
"$UMBRIEL" settle
wait_for_layout scrolling
wait_for_one_group group-a 2
if [[ $("$UMBRIEL" windows --json | jq -c 'map([.x, .y, .w, .h]) | unique') != "$before_switch" ]]; then
  echo "the mode switch did not restore the single group box: $("$UMBRIEL" windows --json)"
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

# A window opened on another workspace's normal scrolling workspace, dragged in with Mod, becomes a tab of the same
# group instead of opening a column beside it, and leaves its own workspace.
spawn_client group-c
wait_for_windows 3
"$UMBRIEL" settle
for _ in $(seq 50); do
  [[ $("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-c") | .tabbed') == false ]] && break
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
pointer mod logo move "$start_x" "$start_y" press "$BTN_LEFT" move "$((start_x - 80))" "$start_y" pause 200 \
  move "$drop_x" "$drop_y" pause 300 release "$BTN_LEFT" mod none
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

# A normal workspace already holds one column at its 0.25 default. Moving a tab out of the single group must inherit
# that destination width, not the group's full-width box.
spawn_client dest-baseline
wait_for_windows 4
"$UMBRIEL" settle
wait_for_title dest-baseline 'any(.[]; .title == $title and .tabbed == false and (.workspace | startswith("HEADLESS-2:")))'
baseline_width=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "dest-baseline") | .w')
group_width=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-c") | .w')
if (( baseline_width >= group_width )); then
  echo "expected the destination's own column to be narrower than the single group, got $baseline_width and $group_width"
  exit 1
fi

group_c_id=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-c") | .id')
"$UMBRIEL" msg window-focus "$group_c_id" > /dev/null
"$UMBRIEL" settle
left_x=$("$UMBRIEL" outputs --json | jq -r '.[] | select(.name == "HEADLESS-1") | .position.x')
right_x=$("$UMBRIEL" outputs --json | jq -r '.[] | select(.name == "HEADLESS-2") | .position.x')
if (( right_x > left_x )); then
  move_action=window-move-or-output-right
else
  move_action=window-move-or-output-left
fi
"$UMBRIEL" msg "$move_action" > /dev/null
wait_for_workspace group-c HEADLESS-2
"$UMBRIEL" settle

moved_width=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-c") | .w')
if [[ $moved_width != "$baseline_width" ]]; then
  echo "a tab leaving the single group took its full width instead of the destination's $baseline_width: $("$UMBRIEL" windows --json)"
  exit 1
fi
if ! "$UMBRIEL" windows --json | jq -e '.[] | select(.title == "group-c") | (.tabbed | not) and .maximized == false' > /dev/null; then
  echo "the tab leaving the single group did not become a normal column: $("$UMBRIEL" windows --json)"
  exit 1
fi

# A title-bar window joining the group gets a first configure equal to the group's arranged box; the tab bar reserve
# is already inside it and no title bar is subtracted for a tab.
group_box=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-a") | "\(.w)x\(.h)"')
LOG_CONFIGURES=1 FOLLOW_CONFIGURES=1 "$CLIENT" first-configure 800 600 > "$UMBRIEL_RUNTIME_DIR/first-configure.log" 2>&1 &
wait_for_windows 5
"$UMBRIEL" settle
wait_for_title first-configure 'any(.[]; .title == $title and .tabbed)'
first_configure=$(awk -F= '/^configured-size=/{print $2; exit}' "$UMBRIEL_RUNTIME_DIR/first-configure.log")
arranged=$("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "first-configure") | "\(.w)x\(.h)"')
if [[ -z $first_configure || $first_configure != "$arranged" || $arranged != "$group_box" ]]; then
  echo "title-bar first configure $first_configure did not match the group box $group_box (arranged $arranged): $(< "$UMBRIEL_RUNTIME_DIR/first-configure.log")"
  exit 1
fi

echo "the single group ignored named-column, extent, and display rules, left column-scoped actions inert, kept the focused tab through a mode switch, took a dragged-in window at the new-tab position, let a leaving tab take the destination workspace's width, and gave a title-bar arrival a first configure matching its box"
