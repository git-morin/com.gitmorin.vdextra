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
make tombstones-clean  delete native crash dumps, so the next crash is unambiguous
```

`make lint` needs no SDK, so it is the fast gate: `nim check`, `nimpretty`, and `clang-format`
(install it with `pip install 'clang-format==23.1.3'` — CI pins the same version, so an image
upgrade cannot reformat untouched code and fail the gate).

Two of those targets exist because their absence kept costing time: wireless adb drops whenever
the headset idles and a stale connection reports `device` while every command fails, so
`connect` retries until a shell genuinely answers; and `logcat -t` truncates *before* the tag
filter is applied, silently reporting nothing at all, so `logs-dump` never passes it.

## How Nim fits in

The native half is Nim plus a small C shim; there is no C++ of our own left. Nim is not a second
cross-compiler here — CMake runs it as a code generator that emits C, which the NDK's clang then
compiles, so one toolchain stays responsible for the ABI, sysroot and flags.

CMake invokes `nim` at *configure* time, because it needs the generated file list before it can
define the target. Re-run the configure step after editing a `.nim` file.

`init.c` keeps two jobs that are genuinely better in C: calling `NimMain()` from `JNI_OnLoad`
(Nim is built `--noMain:on`, so nothing initialises its runtime, and `JNI_OnLoad` runs inside
`System.loadLibrary` before any native method is reachable), and walking the two `jobjectArray`s
of the dictionary, which is more direct through the C JNI interface than through Nim's FFI.

## The three settings that keep Nim alive inside Mono

All three live in [`app/src/main/nim/nim.cfg`](../app/src/main/nim/nim.cfg), so a bare
`nim check` and the CMake build cannot drift. Each was learned from a silent process death.

- **`-d:noSignalHandler`** — Mono drives implicit null checks, GC write barriers and thread
  suspension through `SIGSEGV`. Nim registers its own handler in `PreMain`, which turned the
  first signal Mono would have handled itself into a Nim fatal error and a silent `quit()` —
  no tombstone, nothing in the crash buffer.
- **`-d:useMalloc`** — Nim's own allocator keeps per-thread heaps that it initialises when *it*
  creates a thread. Every thread here belongs to Mono or Android, so that state never exists and
  the first allocation on one dereferenced a null thread-local heap. libc's allocator needs no
  per-thread setup.
- **`--mm:atomicArc`** — objects cross those threads, so plain refcounts are a race.

A corollary worth keeping in mind: a Nim exception unwinding into Mono's stack frames is
undefined, so every hook body is wrapped to log and let the original call proceed. That cannot
catch a segfault — only removing the signal handler made real crashes visible as tombstones.

## Why Dobby is vendored

Hooks go through a vendored copy of [Dobby](https://github.com/JingMatrix/Dobby) rather than the
host framework's `hook_func`. Registering as a `native_init.list` module makes the framework
install a global inline hook on the linker's own `do_dlopen`, and on this device that corrupts
register state in unrelated linker code, crashing the process on its next unrelated `dlopen`.
Never hooking `do_dlopen` at all sidesteps it.
