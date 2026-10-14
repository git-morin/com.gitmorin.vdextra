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

- **Interface translation** — inject a translation over Virtual Desktop's English UI. Follows your system language by default and falls back to English; pick any bundled language explicitly to override. Includes a CJK font fix.
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

Requires JDK 17, the Android SDK (compileSdk 34, NDK 27.0.12077973, CMake) and
[Nim](https://nim-lang.org) 2.2.x on `PATH`.

```bash
export JAVA_HOME=/path/to/jdk-17
./gradlew :app:assembleRelease
```

The native half is Nim plus a small C shim. Nim is not a second cross-compiler here — CMake runs
it as a code generator that emits C, which the NDK's clang then compiles, so one toolchain stays
responsible for the ABI, sysroot and flags. CMake invokes `nim` at configure time because it
needs the generated file list before it can define the target, so re-run the configure step
after editing a `.nim` file.

Three Nim settings are load-bearing for running inside Virtual Desktop's process, and all three
were learned the hard way (see `src/main/cpp/CMakeLists.txt`):

- `-d:noSignalHandler` — Mono drives implicit null checks, GC write barriers and thread
  suspension through `SIGSEGV`. Nim registering its own handler turns the first such signal into
  a Nim fatal error and a silent `quit()`.
- `-d:useMalloc` — Nim's allocator keeps per-thread heaps it initialises when it creates a
  thread. Every thread here is Mono's or Android's, so that state never exists and the first
  allocation on one dereferences a null thread-local heap.
- `--mm:atomicArc` — objects cross those threads, so refcounts have to be atomic.

## Adding a translation

A language is just a dictionary file named after its BCP-47 tag:

```
app/src/main/assets/dict/<tag>.json      e.g. zh.json, fr.json, pt-BR.json
```

Each file maps Virtual Desktop's own English UI string to its translation. Any string absent
from the file is left untouched, so a partial dictionary is perfectly valid:

```json
{
  "Unable to retrieve your computers": "无法获取您的电脑列表",
  "Connect": "连接"
}
```

Drop the file in and rebuild — it appears in the UI-language picker automatically. There is no
list to register it in and no code to change; the picker enumerates `assets/dict/` and takes
each language's display name from its tag. Adding `fr.json` also makes French the default on
French-language headsets, since an unset picker follows the system language.

Language selection resolves in this order:

1. The language explicitly chosen in the picker, if there is one — including English, which is
   stored as "no dictionary" rather than as a reverse translation.
2. Otherwise the best bundled match for the system's languages, in the user's own order of
   preference: exact tag (`pt-BR`), then bare language (`pt`), then any region of that language
   (a `pt-PT` device still gets a bundled `pt-BR` dictionary).
3. Otherwise English, by applying no dictionary at all.

One caveat worth knowing: Virtual Desktop's own font is swapped for a full-coverage one only
when a string contains a codepoint above `U+2E7F` (`hasCjk` in `native.cpp`). Latin-script
languages render on the stock font and need nothing extra, but scripts below that threshold
that the stock font lacks — Cyrillic and Greek in particular — need that check generalised
first, or they render as missing-glyph boxes.

## Notes

- This module does not provide anything related to store authorization! Make sure your account owns a legitimate Virtual Desktop purchase.
- Setting the bitrate multiplier too high may exceed your encode/decode/network capacity, causing stutter or latency — choose a sensible max bitrate.

## License

[MIT](LICENSE). Original work © [ghitori](https://github.com/ghitori) ([ghitori/vdplus](https://github.com/ghitori/vdplus)). Modifications © git-morin.
