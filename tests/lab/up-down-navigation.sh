#!/bin/bash

omarchy_host_test() {
  local candidate_dir expected_down expected_up
  candidate_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

  log "Staging and enabling the local AltSwitch candidate"
  tar --exclude=.git -C "$candidate_dir" -cf - . | ssh_guest \
    "rm -rf /tmp/omarchy-altswitch-candidate && \
     mkdir -p /tmp/omarchy-altswitch-candidate && \
     tar -C /tmp/omarchy-altswitch-candidate -xf -"
  ssh_guest "git -C /tmp/omarchy-altswitch-candidate init -q && \
    git -C /tmp/omarchy-altswitch-candidate add . && \
    git -C /tmp/omarchy-altswitch-candidate \
      -c user.name=PluginLab -c user.email=lab@invalid commit -qm candidate"

  ssh_session "rm -rf \"\$HOME/.config/omarchy/plugins/io.github.pablo-merino.altswitch\" && \
    omarchy-plugin-add /tmp/omarchy-altswitch-candidate --enable --yes && \
    printf '%s\n' \
      'dofile(os.getenv(\"HOME\") .. \"/.config/omarchy/plugins/io.github.pablo-merino.altswitch/altswitch.lua\")' \
      >>\"\$HOME/.config/hypr/bindings.lua\" && \
    hyprctl reload >/dev/null"

  wait_for_guest_state "candidate bindings load without compositor errors" 15 ssh_session \
    "test -z \"\$(hyprctl configerrors)\" && \
     omarchy-plugin-list --json | jq -e \
       'any(.[]; .id == \"io.github.pablo-merino.altswitch\" and .enabled == true)'" || return 1

  for number in 1 2 3; do
    ssh_session "setsid uwsm-app -- xdg-terminal-exec \
      --title='AltSwitch Arrow Fixture $number' \
      -e bash -c 'sleep 120' >/dev/null 2>&1 &" || return 1
    wait_for_guest_state "arrow fixture $number is mapped" 15 ssh_session \
      "hyprctl -j clients | jq -e \
        'any(.[]; .title == \"AltSwitch Arrow Fixture $number\" and .mapped == true)'" || return 1
  done

  expected_down="$(ssh_session "hyprctl -j clients | jq -er \
    '[.[] | select(.mapped == true and ((.workspace.name // \"\") | startswith(\"special:\") | not))] \
     | sort_by(.focusHistoryID) | .[1].address'")" || return 1
  [[ -n $expected_down ]] || return 1

  press alt-down
  wait_for_guest_state "ALT+DOWN focuses the next window" 10 ssh_session \
    "hyprctl -j activewindow | jq -e '.address == \"$expected_down\"' && \
     test \"\$(omarchy-shell altswitch state)\" = closed" || return 1

  expected_up="$(ssh_session "hyprctl -j clients | jq -er \
    '[.[] | select(.mapped == true and ((.workspace.name // \"\") | startswith(\"special:\") | not))] \
     | sort_by(.focusHistoryID) | .[-1].address'")" || return 1
  [[ -n $expected_up ]] || return 1

  press alt-up
  wait_for_guest_state "ALT+UP wraps to and focuses the oldest window" 10 ssh_session \
    "hyprctl -j activewindow | jq -e '.address == \"$expected_up\"' && \
     test \"\$(omarchy-shell altswitch state)\" = closed" || return 1

  ssh_session "hyprctl -j clients" >"$RUN_DIR/altswitch-arrow-clients.json" || return 1
  ssh_session "hyprctl -j activewindow" >"$RUN_DIR/altswitch-arrow-active-window.json" || return 1
  capture_console "success-altswitch-arrow-navigation"

  printf 'ok - ALT+DOWN and ALT+UP selected the expected windows through real virtual keyboard input\n'
}
