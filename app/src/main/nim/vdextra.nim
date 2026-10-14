import std/[strutils, atomics, os]
import vdlog, elfsyms, mono, hooks

const MONO_SONAME = "libmonosgen-2.0.so"

type GetPtrFn = proc(): pointer {.cdecl, gcsafe.}

var
  gMono: ElfSyms
  gAttached: Atomic[bool]
  gPollStarted: Atomic[bool]
  gPollThread: Thread[void]

proc hex(p: pointer): string =
  "0x" & toLowerAscii(toHex(cast[uint64](p), 1))

proc monoSymOf(name: cstring): pointer {.cdecl.} =
  if not gMono.ok: nil else: gMono.sym(name)

proc callPtrFn(s: ElfSyms, name: cstring): pointer =
  let fn = cast[GetPtrFn](s.sym(name))
  if fn == nil: nil else: fn()

proc runtimeIsUp(s: ElfSyms): bool {.gcsafe.} =
  ## These read globals that stay null until mono_init() has run in *that* image, which is what
  ## lets us ask whether a runtime is up instead of guessing at timing.
  callPtrFn(s, "mono_get_corlib") != nil or callPtrFn(s, "mono_get_root_domain") != nil

proc tryAttachMono(): bool =
  ## Safe to call from several places at once; whichever caller wins installs the hooks and the
  ## rest become no-ops. A false answer means "not ready yet, ask again", never a failure.
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
  ## Only a fallback for the Java-level Runtime.initInternal hook never firing at all - a
  ## future app version renaming or resignaturing it, say. The short delay just lets that hook,
  ## which fires ~70ms in on the right thread, win in the normal case; it is not a correctness
  ## guard, since tryAttachMono refuses to attach to a runtime that is not up yet.
  sleep(2000)
  var i = 0
  while not tryAttachMono():
    if i > 0 and i mod 300 == 0:
      logI("still waiting for a live libmonosgen-2.0.so runtime (" & $(i div 5 + 2) & "s elapsed)")
    sleep(200)
    inc i
  # doSetup's patience lives here rather than in nativeCheckMono: this thread blocks nothing,
  # while that JNI call runs on the app's main thread inside ContentProvider.attachInfo, where
  # the system's bind-application watchdog could kill the process for stalling.
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
  ## Called straight from the Java initInternal hook, on the very thread that just finished
  ## Mono's own bootstrap - so doSetup() runs on a managed thread without any foreign-thread
  ## attach, which is the part every mono_*_attach API refused to give us.
  logI("nativeCheckMono called from the Java initInternal hook")
  for _ in 0 ..< 20:
    if tryAttachMono():
      doSetup()
      return true
    sleep(100)
  false

proc Java_com_gitmorin_vdextra_MainModule_nativeSetNoMusic(env, thiz: pointer, disable: bool)
    {.exportc, cdecl, dynlib.} =
  gNoMusic.store(disable)
  logI("noMusic=" & $disable)

proc Java_com_gitmorin_vdextra_MainModule_nativeSetQuality(
    env, thiz: pointer, enable: bool, mask: int32) {.exportc, cdecl, dynlib.} =
  gQualitySound.store(enable)
  gQualityMask.store(int(mask) and 0x7F)
  logI("quality enable=" & $enable & " mask=" & $gQualityMask.load())

proc Java_com_gitmorin_vdextra_MainModule_nativeSetBitrate(
    env, thiz: pointer, extend, unlock: bool, scale: cfloat) {.exportc, cdecl, dynlib.} =
  var s = float32(scale)
  if not (s >= 1'f32): s = 1'f32      # also catches NaN
  if s > 3'f32: s = 3'f32
  gBitrateExtend.store(extend)
  gBitrateUnlock.store(unlock)
  gBitrateScale.store(s)
  logI("bitrate extend=" & $extend & " unlock=" & $unlock & " scale=" & formatFloat(s, ffDecimal, 2))

proc Java_com_gitmorin_vdextra_MainModule_nativeSetForceLan(env, thiz: pointer, on: bool)
    {.exportc, cdecl, dynlib.} =
  gForceLan.store(on)
  logI("forceLan=" & $on)

proc vdDictPut(k, v: cstring) {.exportc: "vdDictPut", cdecl, dynlib.} =
  dictPut($k, $v)

proc vdDictLogCount() {.exportc: "vdDictLogCount", cdecl, dynlib.} =
  logI("dict=" & $dictLen())
