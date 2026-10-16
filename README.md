<div align="center">
  <img width="160" height="160" alt="VDExtra app icon" src="docs/icon.png" />
  <h1>VDExtra</h1>

  <a href="../../releases/latest"><img alt="stable release" src="https://img.shields.io/github/v/release/git-morin/com.gitmorin.vdextra?display_name=release&label=stable&color=blue"></a>
  <a href="../../releases"><img alt="dev release" src="https://img.shields.io/github/v/release/git-morin/com.gitmorin.vdextra?display_name=release&include_prereleases&label=dev&color=orange"></a>
</div>

Xposed module that adds features to **Virtual Desktop** (VR).

> Does not circumvent the license requirement from the application. Please buy the software it is worth it!

⚠️ EARLY STAGE ⚠️

This project is in its early stages. Currently tested only on my own personal hardware:
- arm64-v8a (Quest 3)
- libxposed API 102 
- Virtual Desktop 1.34.22

The module may misbehave by either not changing anything in VD (failed to hook internals of the app) or by crashing VD at launch (which in the Quest translate to a long load and then a dialog about the app not responding).
If you meet these two major issues then please open an issue with your hardware specifications and the VD version that you are running.

## Features

- **Interface translation**: Translate VD's UI in one of the currently supported languages
  - Contributions to new languages are welcomed. Feel free to submit a merge request (see the [translation doc](docs/translations.md))
- **Extend bitrate range**: Increase the allowed maximum bitrate between VD and the connected machine.
  - ⚠️ Make sure to stay within your bandwidth, you will get choppy performance if you push this beyond your capacity.
- **Remove internal bitrate cap**: Prevent the measured bandwidth (internally from VD) from throttling what actually gets streamed.
  - ⚠️ Does not magically give you bandwidth. This is to prevent VD for meddling with the bitrate's current value when it does its own internal bandwidth check.
  - Generally you want this active if you use `Extend bitrate range` 
- **Disable background music**: Prevent music from playing when VD isn't connected to a machine.
- **Disable performance cue sounds**: Mute the sounds that are added when you edit the performance slider.
- **Force LAN discovery**: Find local PCs even when the remote server is unreachable (for restrictive networks).

## Install

1. Download `vdextra-<version>.apk` from [Releases](../../releases) or the Xposed modules repo and install it.
2. Enable **VDExtra** in your Xposed manager; its static scope should default to Virtual Desktop.
3. Restart Virtual Desktop if it was running. This is required whenever you change the module config.


## License

[MIT](LICENSE). Original work © [ghitori](https://github.com/ghitori)
([ghitori/vdplus](https://github.com/ghitori/vdplus)), relicensed and maintained independently
under the same terms; all credit for the original design and native-hook implementation is
theirs. Modifications © git-morin.
