import std/[strutils, atomics, os]
import vdlog, elfsyms, mono
import hooks/[setup, triggers]

const MONO_SONAME = "libmonosgen-2.0.so"

type GetPtrFn = proc(): pointer {.cdecl, gcsafe.}

var
  gMono: ElfSyms
  gAttached: Atomic[bool]
  gPollStarted: Atomic[bool]
  gPollThread: Thread[void]

proc hex(p: pointer): string =
  let v = cast[uint64](p)
  if v == 0: "0x0" else: "0x" & toLowerAscii(toHex(v, 16)).strip(trailing = false, chars = {'0'})

proc monoSymOf(name: cstring): pointer {.cdecl.} =
  if not gMono.ok: nil else: gMono.sym(name)

proc callPtrFn(s: ElfSyms, name: cstring): pointer =
  let fn = cast[GetPtrFn](s.sym(name))
  if fn == nil: nil else: fn()

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

proc pollForMono() {.thread.} =
  {.cast(gcsafe).}:
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

proc Java_com_gitmorin_vdextra_MainModule_nativeInit(env, thiz: pointer)
    {.exportc, cdecl, dynlib.} =
  var expected = false
  if not gPollStarted.compareExchange(expected, true): return
  createThread(gPollThread, pollForMono)

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

proc Java_com_gitmorin_vdextra_MainModule_nativeSetSettingsScroll(
    env, thiz: pointer, enable: bool) {.exportc, cdecl, dynlib.} =
  scrollFeature.enabled.store(enable)
  logI("settingsScroll=" & $enable)

proc vdDictPut(k, v: cstring) {.exportc: "vdDictPut", cdecl, dynlib.} =
  dictPut($k, $v)

proc vdDictLogCount() {.exportc: "vdDictLogCount", cdecl, dynlib.} =
  logI("dict=" & $dictLen())
