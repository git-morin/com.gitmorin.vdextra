# VDExtra

<img width="160" height="160" alt="VDExtra app icon" src="app/src/main/res/drawable/ic_launcher.png" />

VDExtra is a fork of [ghitori/vdplus](https://github.com/ghitori/vdplus), relicensed and
maintained independently under the same MIT terms. All credit for the original design and
native-hook implementation goes to [ghitori](https://github.com/ghitori). This fork swaps in a
new app identity (package, icon) and adds proper i18n to the module's own UI, with English as
the default language and Chinese available as an alternate locale (the module's own UI was
previously Chinese-only; the original project's *interface translation* feature, which patches
Virtual Desktop's own UI text, is unrelated and unchanged).

## About

This project is an **LSPosed** enhancement module for Virtual Desktop (a VR streaming client).

> For Android (arm64-v8a) + LSPosed (libxposed API 102) / verified on Quest 3 + Virtual Desktop 1.34.22

## Features

- **Interface translation** — built-in dictionary, supports importing a custom JSON dictionary, with a CJK font fix.
- **Disable background music** — stop auto-playing music while not connected.
- **Disable performance cue sounds** — independently mute 7 cue sounds ~(no more jump scares)~.
- **Extended bitrate range** — raise the desktop / VR max bitrate (1-3x multiplier, default 2x).
- **Remove auto speed-test bitrate cap** — reapply settings without the post-speedtest bandwidth cap.
- **Force LAN discovery** — keep scanning for local devices even when the remote server is unreachable (for restrictive networks).
- **More features in progress~**

## Install

1. Download `app-release.apk` from Releases and install it.
2. Enable **VDExtra** in LSPosed; its static scope defaults to **Virtual Desktop**.
3. Force-stop and restart Virtual Desktop.

## Build

Requires JDK 17 and the Android SDK (compileSdk 34, NDK 27.0.12077973, CMake).

```bash
export JAVA_HOME=/path/to/jdk-17
./gradlew :app:assembleRelease
```

## Notes

- This module does not provide anything related to store authorization! Make sure your account owns a legitimate Virtual Desktop purchase.
- Setting the bitrate multiplier too high may exceed your encode/decode/network capacity, causing stutter or latency — choose a sensible max bitrate.

## License

[MIT](LICENSE). Original work © [ghitori](https://github.com/ghitori) ([ghitori/vdplus](https://github.com/ghitori/vdplus)). Modifications © git-morin.
