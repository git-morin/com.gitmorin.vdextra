# VDExtra

<img width="160" height="160" alt="VDExtra app icon" src="app/src/main/res/drawable/ic_launcher.png" />

An Xposed module that adds quality-of-life features to **Virtual Desktop**, the VR streaming
client — UI translation, bitrate limits, sound control and LAN discovery.

> arm64-v8a · libxposed API 102 (LSPosed / Vector) · verified on Quest 3 with Virtual Desktop 1.34.22

Forked from [ghitori/vdplus](https://github.com/ghitori/vdplus); see [License](#license).

## Features

- **Interface translation** — inject a translation over Virtual Desktop's English UI. Follows
  your system language by default, falls back to English, and any bundled language can be picked
  explicitly. Includes a CJK font fix.
- **Extended bitrate range** — raise the desktop / VR max bitrate (1–3× multiplier, default 2×).
- **Remove auto speed-test bitrate cap** — reapply settings without the post-speedtest cap.
- **Disable background music** — stop auto-playing music while not connected.
- **Disable performance cue sounds** — mute any of the 7 cue sounds individually.
- **Force LAN discovery** — keep finding local PCs even when the remote server is unreachable,
  for restrictive networks.
- **In-app updates** — stable or dev channel, checked on launch and installable from the app.

## Install

1. Download `vdextra-<version>.apk` from [Releases](../../releases) and install it.
2. Enable **VDExtra** in your Xposed manager; its static scope defaults to Virtual Desktop.
3. Force-stop and restart Virtual Desktop.

Later versions can update themselves from **Options → Updates**.

## Docs

- [Adding a translation](docs/translations.md) — drop in a dictionary, how a language is chosen,
  and the font caveat to know before adding a non-Latin script.
- [Building](docs/building.md) — toolchain, the `make` loop, and how Nim fits into the native
  build.

## Notes

- This module provides nothing related to store authorization. Make sure your account owns a
  legitimate Virtual Desktop purchase.
- A bitrate multiplier set too high can exceed your encode, decode or network capacity and cause
  stutter or latency. Pick a sensible maximum.

## License

[MIT](LICENSE). Original work © [ghitori](https://github.com/ghitori)
([ghitori/vdplus](https://github.com/ghitori/vdplus)), relicensed and maintained independently
under the same terms; all credit for the original design and native-hook implementation is
theirs. Modifications © git-morin.

This fork changes the app identity (package, icon), translates the module's own UI, and rewrote
the native layer in Nim.
