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
make lint              type-check the Nim, check Nim/C/Kotlin formatting, analyse the Kotlin
make fmt               reformat the Nim, C and Kotlin in place
make ship              build in CI, install on the headset, restart Virtual Desktop
make connect           reconnect wireless adb
make logs              follow the VDExtra log
make tombstones-clean  cleanup developpment session
```

### Linting

Every gate runs without the Android SDK, so `make lint` works on a machine that cannot build
the APK. The Nim and C tools come from the environment; ktlint and detekt are pinned jars that
`make tools` fetches into `.tools/` on first use, which is why they are standalone CLIs rather
than Gradle plugins - the Android plugin cannot even configure without the SDK.

`config/detekt.yml` holds only deviations from detekt's defaults, each with the reason it is
off. `config/detekt-baseline.xml` records the findings that already existed, so a run fails
only on *new* ones; regenerate it with `--create-baseline` after deliberately paying some of
that debt down.
