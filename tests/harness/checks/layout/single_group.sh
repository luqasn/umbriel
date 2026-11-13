#!/usr/bin/env bash
# A single-group workspace holds every window in one tab group filling the layout area: a second client shares the
# first's box and is reported as a hidden tab, and clicking a bar slot switches which one shows.
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

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[layout.tabs]
single_group = true

[appearance.tab_bar]
tab_gap = 0

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

if [[ $("$UMBRIEL" workspaces --json | jq -r '.[] | select(.active) | .layout') != scrolling ]]; then
  echo "expected the single-group workspace to keep the scrolling layout: $("$UMBRIEL" workspaces --json)"
  exit 1
fi
wait_for_one_group group-b

# The named-column order rule is ignored: the second arrival stays last instead of sorting before the first.
if [[ $("$UMBRIEL" windows --json | jq -r '.[] | select(.title == "group-a") | .tab_index') != 0 ]]; then
  echo "expected the named-column order rule to leave group-a first: $("$UMBRIEL" windows --json)"
  exit 1
fi

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

echo "single-group workspace held both clients in one full-area tab group, switched by slot, and ignored inapplicable actions"
