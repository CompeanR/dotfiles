#!/usr/bin/env sh
# Focus a real window on the target space/display so yabai never activates
# hidden-but-alive windows (e.g. Superwhisper settings) via display/space focus.
kind=$1 sel=$2
space=$sel
[ "$kind" = display ] && space=$(yabai -m query --spaces --display "$sel" | jq '.[] | select(."is-visible").index')
id=$(yabai -m query --windows --space "$space" 2>/dev/null | jq '[.[] | select(."has-ax-reference" and .subrole == "AXStandardWindow" and (."is-minimized" | not))][0].id // empty')
if [ -n "$id" ]; then yabai -m window --focus "$id"; else yabai -m "$kind" --focus "$sel"; fi
