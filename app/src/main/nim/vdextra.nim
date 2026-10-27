## Our code is almost entirely raw interop - Mono object pointers, Dobby trampolines,
## ELF symbol tables - where nil is a normal value rather than an error. Nimony makes
## every ptr not-nil by default, so this opts the module back into Nim 2 rules; the
## stdlib modules that were ported from Nim do the same.
##
## assumeSync goes with it: the resolved entry points are globals written once while the
## module is loading and only read afterwards, which Nimony's thread-safety analysis cannot
## see. Its own ioring backends opt out the same way.
when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "assumeSync".}

import std/[strutils, atomics, os]
import vdlog, elfsyms, mono, compat
import hooks/[setup, triggers]

const MONO_SONAME = "libmonosgen-2.0.so"

type GetPtrFn = proc(): pointer {.cdecl, gcsafe.}

var
  gMono: ElfSyms
  gAttached: Atomic[bool]
  gPollStarted: Atomic[bool]
  gPollThread: PollThread

proc hex(p: pointer): string =
  let v = cast[uint64](p)
  if v == 0: "0x0"
  else: "0x" & toLowerAscii(toHex(cast[int64](v), 16)).strip(
    trailing = false, chars = {'0'})

proc monoSymOf(name: cstring): pointer {.cdecl.} =
  if not gMono.ok: default(pointer) else: gMono.sym(name)

proc callPtrFn(s: ElfSyms, name: cstring): pointer =
  let fn = asProc[GetPtrFn](s.sym(name))
  if fn == nil: default(pointer) else: fn()

proc runtimeIsUp(s: ElfSyms): bool {.gcsafe.} =
  callPtrFn(s, "mono_get_corlib") != nil or callPtrFn(s, "mono_get_root_domain") != nil

proc tryAttachMono(): bool =
  if gAttached.load(): return true
  if not gMono.ok:
    let s = findLiveImage(MONO_SONAME, runtimeIsUp)
    if not s.ok: return false
    gMono = s
    logI("libmonosgen attached: live runtime at base=" & hex(cast[pointer](s.bias)) &
         " (corlib=" & hex(callPtrFn(s, "mono_get_corlib")) &
         " root_domain=" & hex(callPtrFn(s, "mono_get_root_domain")) &
         ", " & $residentInstances(MONO_SONAME).len & " resident instance(s), " &
         $s.count & " syms)")
  var expected = false
  if not gAttached.compareExchange(expected, true): return true
  resolveMono(monoSymOf)
  installTriggerHooks(monoSymOf)
  true

proc pollBody() =
  sleep(2000)
  var i = 0
  while not tryAttachMono():
    if i > 0 and i mod 300 == 0:
      logI("still waiting for a live libmonosgen-2.0.so runtime (" & $(i div 5 + 2) & "s elapsed)")
    sleep(200)
    inc i
  i = 0
  while not gSetup.load():
    doSetup()
    if gSetup.load(): break
    if i > 0 and i mod 25 == 0: logI("background doSetup retry #" & $i)
    sleep(500)
    inc i

## The poll runs on its own thread and reaches the globals the setup path resolves. Nim 2 needs
## that promise spelled out; Nimony's effect system is opt-in and has no `gcsafe` to cast, so
## only the call is gated rather than the loop above.
proc pollLoop() =
  when defined(nimony):
    pollBody()
  else:
    {.cast(gcsafe).}:
      pollBody()

## The thread entry point. Nim 2 wants `{.thread.}`, which Nimony does not have, so only the
## signature is gated and the body above is shared.
when defined(nimony):
  proc pollForMono(arg: pointer) {.nimcall.} = pollLoop()
else:
  proc pollForMono(arg: pointer) {.thread, nimcall.} = pollLoop()

proc Java_com_gitmorin_vdextra_MainModule_nativeInit(env, thiz: pointer)
    {.exportc, cdecl, dynlib.} =
  var expected = false
  if not gPollStarted.compareExchange(expected, true): return
  startThread(gPollThread, pollForMono)

proc Java_com_gitmorin_vdextra_MainModule_nativeCheckMono(env, thiz: pointer): bool
    {.exportc, cdecl, dynlib.} =
  logI("nativeCheckMono called from the Java initInternal hook")
  for _ in 0 ..< 20:
    if tryAttachMono():
      doSetup()
      return true
    sleep(100)
  false

proc Java_com_gitmorin_vdextra_MainModule_nativeSetMusicVolume(
    env, thiz: pointer, volume: cfloat) {.exportc, cdecl, dynlib.} =
  var v = float32(volume)
  if not (v >= 0'f32): v = 1'f32 # also catches NaN
  if v > 1'f32: v = 1'f32
  musicFeature.volume.store(v)
  logI("musicVolume=" & formatFloat(v, ffDecimal, 2))

proc Java_com_gitmorin_vdextra_MainModule_nativeSetCustomMusic(
    env, cls: pointer, on: bool) {.exportc, cdecl, dynlib.} =
  musicFeature.custom.store(on)
  logI("customMusic=" & $on)

proc Java_com_gitmorin_vdextra_MainModule_nativeMusicState(
    env, cls: pointer): int32 {.exportc, cdecl, dynlib.} =
  int32(musicFeature.state.load())

proc Java_com_gitmorin_vdextra_MainModule_nativeSetQuality(
    env, thiz: pointer, enable: bool, mask: int32) {.exportc, cdecl, dynlib.} =
  cueSoundsFeature.enabled.store(enable)
  cueSoundsFeature.mask.store(int(mask) and 0x7F)
  logI("quality enable=" & $enable & " mask=" & $cueSoundsFeature.mask.load())

proc Java_com_gitmorin_vdextra_MainModule_nativeSetBitrate(
    env, thiz: pointer, extend, unlock: bool, scale: cfloat) {.exportc, cdecl, dynlib.} =
  var s = float32(scale)
  if not (s >= 1'f32): s = 1'f32 # also catches NaN
  if s > 3'f32: s = 3'f32
  bitrateFeature.extend.store(extend)
  bitrateFeature.unlock.store(unlock)
  bitrateFeature.scale.store(s)
  logI("bitrateFeature extend=" & $extend & " unlock=" & $unlock & " scale=" & formatFloat(s,
      ffDecimal, 2))

proc Java_com_gitmorin_vdextra_MainModule_nativeSetForceLan(env, thiz: pointer, on: bool)
    {.exportc, cdecl, dynlib.} =
  forceLanFeature.enabled.store(on)
  logI("forceLanFeature=" & $on)

proc Java_com_gitmorin_vdextra_MainModule_nativeSetSettingsFit(
    env, thiz: pointer, enable: bool, pad: cfloat) {.exportc, cdecl, dynlib.} =
  var t = float32(pad)
  if not (t >= 0'f32): t = 16'f32 # also catches NaN
  if t > 64'f32: t = 64'f32
  fitFeature.enabled.store(enable)
  fitFeature.pad.store(t)
  logI("settingsFit=" & $enable & " pad=" & formatFloat(t, ffDecimal, 0))

proc vdDictPut(k, v: cstring) {.exportc: "vdDictPut", cdecl, dynlib.} =
  dictPut($k, $v)

proc vdDictLogCount() {.exportc: "vdDictLogCount", cdecl, dynlib.} =
  logI("dict=" & $dictLen())
