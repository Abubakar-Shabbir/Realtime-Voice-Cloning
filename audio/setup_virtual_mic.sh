#!/usr/bin/env bash
# Creates: rvc_out (null sink RVC plays into) + rvc_mic (virtual microphone apps select).
set -euo pipefail
STATE="$HOME/rvc-realtime/audio/.modules"
mkdir -p "$(dirname "$STATE")"

DEF_SINK=$(pactl get-default-sink)
DEF_SOURCE=$(pactl get-default-source)

if pactl list short sinks | awk '{print $2}' | grep -qx rvc_out; then
  echo "rvc_out already exists"
else
  # Nested quotes are required: pipewire-pulse cuts unquoted values at the first space.
  pactl load-module module-null-sink sink_name=rvc_out rate=48000 channels=2 \
    "sink_properties=\"device.description='RVC Output (internal)'\"" >> "$STATE"
fi

if pactl list short sources | awk '{print $2}' | grep -qx rvc_mic; then
  echo "rvc_mic already exists"
else
  pactl load-module module-remap-source master=rvc_out.monitor source_name=rvc_mic \
    "source_properties=\"device.description='RVC Virtual Microphone'\"" >> "$STATE"
fi

# Never let the virtual devices hijack the system defaults.
[ "$(pactl get-default-sink)" = "$DEF_SINK" ] || pactl set-default-sink "$DEF_SINK"
[ "$(pactl get-default-source)" = "$DEF_SOURCE" ] || pactl set-default-source "$DEF_SOURCE"

pactl list short sinks | grep rvc_out
pactl list short sources | grep -E "rvc_mic|rvc_out.monitor"
echo "default sink:   $(pactl get-default-sink)"
echo "default source: $(pactl get-default-source)"
