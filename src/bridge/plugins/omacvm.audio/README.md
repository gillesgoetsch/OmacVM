# omacvm.audio

Omarchy bar widget for the Mac host's audio in an OmacVM.app VM. It is a clone of
Omarchy's `omarchy.audio` (MIT, see `LICENSE`), driven by the Mac-side
`omacvm-bridge` helper.

- Volume, mute, input volume and mute, and output/input device switching all
  act on the **Mac** through `omacvm-bridge`.
- The **input level meter** reads the VM side: OmacVM.app feeds the Mac's
  current input into the VM, so PipeWire's default source carries exactly what
  apps in the VM hear. It uses Omarchy's own `PwNodePeakMonitor`.

## Guest requirements

- `/usr/local/bin/omacvm-bridge` and `~/.config/omacvm-bridge/token`.
- PipeWire with ALSA, PulseAudio and JACK support, which stock Omarchy
  expects anyway:

  ```bash
  sudo pacman -S --needed pipewire-alsa pipewire-pulse pipewire-jack
  # pipewire-jack replaces jack2 (it provides libjack)
  systemctl --user restart pipewire pipewire-pulse wireplumber
  ```

  Without them the widget still works, but the meter stays hidden, and only
  one app at a time can use the sound card.
- The VM's own levels must stay at full, because the Mac owns the loudness:
  ALSA `Master` at 0 dB, and the PipeWire sink at 100%:

  ```bash
  amixer -c0 sset Master 0dB unmute
  wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 && wpctl set-mute @DEFAULT_AUDIO_SINK@ 0
  ```

  The widget never touches these (no `wpctl`, no `omarchy-audio-output-volume`).
  Omarchy's own volume keys would, but in full screen the Mac helper takes
  those keys.
