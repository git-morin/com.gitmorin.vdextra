# Building

Requires JDK 17, the Android SDK (compileSdk 34, NDK 27.0.12077973, CMake) and
[Nim](https://nim-lang.org) 2.2.x on `PATH`.

```bash
export JAVA_HOME=/path/to/jdk-17
./gradlew :app:assembleRelease
```

## The development loop

`make help` lists everything. With no Android SDK to hand, compiling happens in CI, and
`make ship` is the whole loop: push, build, download the APK, install it, restart Virtual
Desktop.

```
make lint              type-check the Nim against the android target, check formatting
make ship              build in CI, install on the headset, restart Virtual Desktop
make connect           reconnect wireless adb
make logs              follow the VDExtra log
make tombstones-clean  cleanup developpment session
```
