import std/[atomics, math, strutils]
import vdlog, mono

proc dobbyHook(target, replace: pointer, orig: ptr pointer): cint
  {.importc: "DobbyHook", header: "dobby.h", gcsafe.}

proc hook(target, replace: pointer, orig: ptr pointer): bool {.discardable.} =
  ## Dobby answers 0 on success.
  if target == nil: return false
  dobbyHook(target, replace, orig) == 0

const
  SER_CAP = 40        ## how many Serialize calls to watch before giving up on font capture

var
  gNoMusic*: Atomic[bool]
  gQualitySound*: Atomic[bool]
  gQualityMask*: Atomic[int]
  gBitrateScale*: Atomic[float32]
  gBitrateExtend*: Atomic[bool]
  gBitrateUnlock*: Atomic[bool]
  gForceLan*: Atomic[bool]

var
  gSetup*: Atomic[bool]
  gInSetup: Atomic[bool]
  gTextHooked, gSerHooked, gCmHooked: Atomic[bool]
  gMusicHooked, gMusicTried: Atomic[bool]
  gQualityTried, gBitrateTried, gForceLanTried: Atomic[bool]
  serCount = 0
  serDone = false

type
  SetTextFn = proc(tb: pointer, s: MonoString) {.cdecl, gcsafe.}
  SetFontFn = proc(tb: pointer, f: MonoObject) {.cdecl, gcsafe.}
  GetTextFn = proc(tb: pointer): MonoString {.cdecl, gcsafe.}
  LdstrFn = proc(a0, a1, a2, a3: pointer): MonoString {.cdecl, gcsafe.}
  SerializeFn = proc(x0, x1, x2, x3: pointer) {.cdecl, gcsafe.}
  Load3Fn = proc(x0, x1, x2, x3: pointer): MonoObject {.cdecl, gcsafe.}
  Load2Fn = proc(x0, x1, x2: pointer): MonoObject {.cdecl, gcsafe.}
  ObjNewFn = proc(d: MonoDomain, k: MonoClass): MonoObject {.cdecl, gcsafe.}
  JitInitFn = proc(name: cstring): MonoDomain {.cdecl, gcsafe.}
  JitExecFn = proc(d: MonoDomain, asmv: pointer, argc: cint,
                   argv: pointer): cint {.cdecl, gcsafe.}
  RunMainFn = proc(asmv: pointer, argc: cint, argv: pointer): cint {.cdecl, gcsafe.}
  VoidFn = proc(self: pointer) {.cdecl, gcsafe.}
  MinMax1Fn = proc(a: int32): int32 {.cdecl, gcsafe.}
  MinMax3Fn = proc(a, b, c: int32): int32 {.cdecl, gcsafe.}
  CalcBitrate2Fn = proc(a: int32, t: cfloat): int32 {.cdecl, gcsafe.}
  BitrateStr2Fn = proc(a: int32, t: cfloat): MonoString {.cdecl, gcsafe.}
  SetInt1Fn = proc(self: pointer, v: int32) {.cdecl, gcsafe.}
  SetFloat1Fn = proc(self: pointer, v: cfloat) {.cdecl, gcsafe.}
  GetBoolFn = proc(self: pointer): bool {.cdecl, gcsafe.}
  SetBoolFn = proc(self: pointer, v: bool) {.cdecl, gcsafe.}
  SerializerObjectFn = proc(obj, writer: pointer) {.cdecl, gcsafe.}

var
  getTextFn: GetTextFn
  origSetText: SetTextFn
  origSetFont: SetFontFn
  origLdstr: LdstrFn
  origSerialize: SerializeFn
  origLoad3: Load3Fn
  origLoad2: Load2Fn
  origObjNew: ObjNewFn
  origJitInit: JitInitFn
  origJitExec: JitExecFn
  origRunMain: RunMainFn
  origMusicPlay: VoidFn

proc doSetup*()

# A Nim exception unwinding into Mono's stack frames is undefined, and a Defect escaping a
# hook took the whole process down with no tombstone and nothing in logcat. Every hook body
# is wrapped so a failure is logged and the original still runs.
template guard(what: string, body: untyped) =
  try:
    body
  except CatchableError as e:
    logE("hook " & what & " raised: " & e.msg)
  except Defect as e:
    logE("hook " & what & " defect: " & e.msg)

proc hookSetText(tb: pointer, text: MonoString) {.cdecl.} =
  ## Translation only. Font handling is left entirely to set_Font, so that this setter never
  ## writes Font re-entrantly.
  var s = text
  guard "set_Text":
    let t = translate(text)
    if t != nil: s = t
  if origSetText != nil: origSetText(tb, s)

proc hookSetFont(tb: pointer, newFont: MonoObject) {.cdecl.} =
  var cur = newFont
  guard "set_Font":
    let gf = goodFont()
    if gf != nil and cur != nil and cur != gf:
      var needsFull = false
      if getTextFn != nil:
        let p = getTextFn(tb)
        needsFull = hasCjk(monoStrChars(p), monoStrLen(p))
      if needsFull and glyphCount(cur) < FULL:
        let repl = pickReplacement(fontSize(cur))
        if repl != nil and repl != cur: cur = repl
  if origSetFont != nil: origSetFont(tb, cur)

proc hookMusicPlay(self: pointer) {.cdecl.} =
  if gNoMusic.load(): return
  if origMusicPlay != nil: origMusicPlay(self)

var gOrigSound: array[7, pointer]

template defMuteSound(idx: static int, name: untyped) =
  proc name(self: pointer) {.cdecl.} =
    if gQualitySound.load() and (gQualityMask.load() and (1 shl idx)) != 0: return
    if gOrigSound[idx] != nil: cast[VoidFn](gOrigSound[idx])(self)

defMuteSound(0, muteSound0)
defMuteSound(1, muteSound1)
defMuteSound(2, muteSound2)
defMuteSound(3, muteSound3)
defMuteSound(4, muteSound4)
defMuteSound(5, muteSound5)
defMuteSound(6, muteSound6)

proc installQualitySoundHooks(): bool =
  let ss = getClass("VirtualDesktop.Mobile.SoundSystem, VirtualDesktop.Mobile")
  if ss == nil:
    logE("SoundSystem class not found")
    return false
  const names = ["PlayPotato", "PlayUltra", "PlayGodlike", "PlayMonster",
                 "PlayRampage", "PlayUnstoppable", "PlayHolyShit"]
  let repls = [cast[pointer](muteSound0), cast[pointer](muteSound1),
               cast[pointer](muteSound2), cast[pointer](muteSound3),
               cast[pointer](muteSound4), cast[pointer](muteSound5),
               cast[pointer](muteSound6)]
  var ok = 0
  for i in 0 ..< 7:
    let a = methodAddr(ss, names[i], 0)
    if a != nil and hook(a, repls[i], addr gOrigSound[i]): inc ok
  logI("hooked quality sounds: " & $ok & "/7 mask=" & $gQualityMask.load())
  true

# The internal max-lookup tables (GetMax*Bitrate) are scaled locally; the sender normalises
# tiers via k=(max*s-min)/(max-min). The table hook can be bypassed by JIT inlining, so the
# first outer call probes for it: hit -> table mode, miss -> multiply the outer input by k.
var
  fnMinDesk, fnMinVR: MinMax1Fn          ## originals, used only to compute k
  origMaxDesk: MinMax1Fn
  origMaxVR: MinMax3Fn
  origDesktopBitrate: CalcBitrate2Fn
  origDesktopBitrateString: BitrateStr2Fn
  gDeskMode: Atomic[int]                 ## 0=unknown 1=table 2=outer
  origSettingsMeasured: VoidFn
  origLimitSliderSetLimit: SetFloat1Fn
  origSetHmdType, origSetActiveCodec, origSetFoveated: SetInt1Fn
  origSetMeasuredBandwidth: SetInt1Fn
  origSendReload: VoidFn
  gSpeedtestDone: Atomic[bool]
  gHmd, gCodec, gFov: Atomic[int32]
  gMobileSettings: pointer               ## SharedMobileSettings instance, for full resends
  origSerializerObject: SerializerObjectFn
  gClsUserSettings: MonoClass
  gUserSettingsPin: pointer
  origUserSendReload: VoidFn
  gFieldDesktopLimit, gFieldVRLimit: MonoField
  origSetDesktopLimit, origSetVRLimit: SetFloat1Fn

var
  tProbeHit {.threadvar.}: bool
  tInStrDesktop {.threadvar.}: bool
  tDeskLimitCtx {.threadvar.}: bool

proc rateMul(): float32 =
  let s = gBitrateScale.load()
  if gBitrateExtend.load() and s > 0'f32: s else: 1'f32

proc scaleMax(v: int32): int32 =
  # Saturate rather than wrap. The C++ this replaces relied on a C cast quietly truncating on
  # overflow; Nim range-checks the same conversion and a Defect here killed the process.
  let scaled = float64(v) * float64(rateMul())
  if scaled >= float64(high(int32)): high(int32)
  elif scaled <= float64(low(int32)): low(int32)
  else: int32(scaled)

proc kCalc(mn, mx: float32): float32 =
  let s = rateMul()
  if s <= 1'f32: return 1'f32
  if mx <= mn: return s
  float32((mx * s - mn) / (mx - mn))

proc kDesktopFor(hmd: int32): float32 =
  if hmd < 0 or fnMinDesk == nil or origMaxDesk == nil: return rateMul()
  kCalc(float32(fnMinDesk(hmd)), float32(origMaxDesk(hmd)))

proc kVRFor(hmd, codec, fov: int32): float32 =
  if hmd < 0 or codec < 0 or fnMinVR == nil or origMaxVR == nil: return rateMul()
  kCalc(float32(fnMinVR(hmd)), float32(origMaxVR(hmd, codec, fov)))

proc kDesktop(): float32 = kDesktopFor(gHmd.load())
proc kVR(): float32 = kVRFor(gHmd.load(), gCodec.load(), gFov.load())

proc hookMaxDesk(hmd: int32): int32 {.cdecl.} =
  if gDeskMode.load() == 2:
    return if origMaxDesk != nil: origMaxDesk(hmd) else: 0
  tProbeHit = true
  scaleMax(if origMaxDesk != nil: origMaxDesk(hmd) else: 0)

proc hookMaxVR(hmd, codec, fov: int32): int32 {.cdecl.} =
  scaleMax(if origMaxVR != nil: origMaxVR(hmd, codec, fov) else: 0)

proc hookDesktopBitrate(hmd: int32, t: cfloat): int32 {.cdecl.} =
  if origDesktopBitrate == nil: return 0
  if tInStrDesktop: return origDesktopBitrate(hmd, t)
  let m = gDeskMode.load()
  if m == 1: return origDesktopBitrate(hmd, t)
  if m == 2: return origDesktopBitrate(hmd, cfloat(t * kDesktopFor(hmd)))
  tProbeHit = false
  let r = origDesktopBitrate(hmd, t)
  if tProbeHit:
    gDeskMode.store(1)
    logI("bitrate desktop: table hook ACTIVE (direct)")
    return r
  gDeskMode.store(2)
  logI("bitrate desktop: table inlined -> outer hook")
  origDesktopBitrate(hmd, cfloat(t * kDesktopFor(hmd)))

proc hookDesktopBitrateString(hmd: int32, t: cfloat): MonoString {.cdecl.} =
  if origDesktopBitrateString == nil: return nil
  if gDeskMode.load() != 2: return origDesktopBitrateString(hmd, t)
  tInStrDesktop = true
  result = origDesktopBitrateString(hmd, cfloat(t * kDesktopFor(hmd)))
  tInStrDesktop = false

# Desktop fallback mode: the UI multiplies the tier by k, so divide by k first while the
# speed-test soft limit is being computed, then restore it.
proc hookSettingsMeasured(self: pointer) {.cdecl.} =
  tDeskLimitCtx = true
  if origSettingsMeasured != nil: origSettingsMeasured(self)
  tDeskLimitCtx = false

proc hookLimitSliderSetLimit(self: pointer, v: cfloat) {.cdecl.} =
  var vv = v
  if gDeskMode.load() == 2 and tDeskLimitCtx:
    let k = kDesktop()
    if k > 1'f32: vv = cfloat(vv / k)
  if origLimitSliderSetLimit != nil: origLimitSliderSetLimit(self, vv)

proc captureMobile(self: pointer) =
  if self != nil and gMobileSettings == nil:
    discard pin(self)
    gMobileSettings = self

proc hookCaptureHmd(self: pointer, v: int32) {.cdecl.} =
  gHmd.store(v)
  captureMobile(self)
  if origSetHmdType != nil: origSetHmdType(self, v)

proc hookCaptureCodec(self: pointer, v: int32) {.cdecl.} =
  gCodec.store(v)
  captureMobile(self)
  if origSetActiveCodec != nil: origSetActiveCodec(self, v)

proc hookCaptureFov(self: pointer, v: int32) {.cdecl.} =
  gFov.store(v)
  captureMobile(self)
  if origSetFoveated != nil: origSetFoveated(self, v)

proc sanitiseLimit(v: cfloat): cfloat =
  if v != v: 0'f32          # NaN
  elif v < 0'f32: 0'f32
  else: v

proc rememberUserSettings(self: pointer) =
  if gUserSettingsPin == nil:
    let gh = pin(self)
    if gh != 0'u32: gUserSettingsPin = moved(gh)

proc resendFullPacket(pinned: pointer) =
  ## Only after the speed test: resending earlier would emit a packet with meas=0.
  if rateMul() > 1'f32 and gSpeedtestDone.load():
    if origUserSendReload != nil: origUserSendReload(pinned)
    if gMobileSettings != nil and origSendReload != nil: origSendReload(gMobileSettings)

# Incremental update: write only the baseline value (already scaled locally via the lookup
# table), then resend the full packet, which the sender multiplies by k.
proc hookSetDesktopLimit(self: pointer, v: cfloat) {.cdecl.} =
  if origSetDesktopLimit == nil: return
  rememberUserSettings(self)
  let h = pin(self)
  let p = if h != 0'u32: moved(h) else: self
  origSetDesktopLimit(p, sanitiseLimit(v))
  resendFullPacket(p)
  unpin(h)

proc hookSetVRLimit(self: pointer, v: cfloat) {.cdecl.} =
  if origSetVRLimit == nil: return
  rememberUserSettings(self)
  let h = pin(self)
  let p = if h != 0'u32: moved(h) else: self
  origSetVRLimit(p, sanitiseLimit(v))
  resendFullPacket(p)
  unpin(h)

proc hookSerializerObject(obj, writer: pointer) {.cdecl.} =
  ## Full packet: multiply the tier by k before serialising and restore it after, without
  ## triggering a local recalculation.
  if origSerializerObject == nil: return
  if gUserSettingsPin == nil and obj != nil and gClsUserSettings != nil and
     pObjGetClass != nil and pObjGetClass(obj) == gClsUserSettings:
    rememberUserSettings(obj)
  if rateMul() <= 1'f32 or obj == nil or gClsUserSettings == nil or
     gFieldDesktopLimit == nil or gFieldVRLimit == nil or pObjGetClass == nil or
     pObjGetClass(obj) != gClsUserSettings:
    origSerializerObject(obj, writer)
    return
  let h = pin(obj)
  let p = if h != 0'u32: moved(h) else: obj
  let
    d0 = fieldGetF32(p, gFieldDesktopLimit)
    v0 = fieldGetF32(p, gFieldVRLimit)
  fieldSetF32(p, gFieldDesktopLimit, d0 * kDesktop())
  fieldSetF32(p, gFieldVRLimit, v0 * kVR())
  origSerializerObject(p, writer)
  fieldSetF32(p, gFieldDesktopLimit, d0)
  fieldSetF32(p, gFieldVRLimit, v0)
  unpin(h)

proc hookSetMeasuredBandwidth(self: pointer, v: int32) {.cdecl.} =
  ## Unlock pins the measurement to int32 max; 10G would overflow int32.
  captureMobile(self)
  let firstReal = v > 0'i32 and not gSpeedtestDone.load()
  var outv = v
  if gBitrateUnlock.load() and (gSpeedtestDone.load() or firstReal): outv = high(int32)
  if firstReal: gSpeedtestDone.store(true)
  if origSetMeasuredBandwidth != nil: origSetMeasuredBandwidth(self, outv)
  if firstReal:
    if origSendReload != nil: origSendReload(self)
    if origUserSendReload != nil and gUserSettingsPin != nil:
      origUserSendReload(gUserSettingsPin)

proc findInherited(c: MonoClass, name: string): pointer =
  ## SendSettingsReload lives on a base class; walk up a few levels for it.
  var cur = c
  for _ in 0 ..< 4:
    if cur == nil: break
    let a = methodAddr(cur, name, 0)
    if a != nil: return a
    cur = pClassGetParent(cur)
  nil

proc installBitrateHooks(): bool =
  var ok = 0
  let hx = getClass("Xenko.VR.HmdResolutionTypeExtensions, VirtualDesktop.Mobile.Shared")
  if hx != nil:
    fnMinDesk = cast[MinMax1Fn](methodAddr(hx, "GetMinDesktopBitrate", 1))
    fnMinVR = cast[MinMax1Fn](methodAddr(hx, "GetMinVRBitrate", 1))
    if hook(methodAddr(hx, "GetMaxDesktopBitrate", 1), cast[pointer](hookMaxDesk),
            cast[ptr pointer](addr origMaxDesk)): inc ok
    if hook(methodAddr(hx, "GetMaxVRBitrate", 3), cast[pointer](hookMaxVR),
            cast[ptr pointer](addr origMaxVR)): inc ok
    if hook(methodAddr(hx, "GetDesktopBitrate", 2), cast[pointer](hookDesktopBitrate),
            cast[ptr pointer](addr origDesktopBitrate)): inc ok
    if hook(methodAddr(hx, "GetDesktopBitrateString", 2),
            cast[pointer](hookDesktopBitrateString),
            cast[ptr pointer](addr origDesktopBitrateString)): inc ok
  else:
    logE("HmdResolutionTypeExtensions class not found")

  let us = getClass("VirtualDesktop.Mobile.SharedUserSettings, VirtualDesktop.Mobile.Shared")
  if us != nil:
    if pClassGetField != nil:
      gFieldDesktopLimit = pClassGetField(us, "_desktopBitrateLimit")
      gFieldVRLimit = pClassGetField(us, "_vrBitrateLimit")
    if hook(methodAddr(us, "set_DesktopBitrateLimit", 1),
            cast[pointer](hookSetDesktopLimit),
            cast[ptr pointer](addr origSetDesktopLimit)): inc ok
    if hook(methodAddr(us, "set_VRBitrateLimit", 1), cast[pointer](hookSetVRLimit),
            cast[ptr pointer](addr origSetVRLimit)): inc ok
  else:
    logE("SharedUserSettings class not found")
  gClsUserSettings = us
  if us != nil and pClassGetParent != nil:
    origUserSendReload = cast[VoidFn](findInherited(pClassGetParent(us), "SendSettingsReload"))

  let ms = getClass("VirtualDesktop.Mobile.SharedMobileSettings, VirtualDesktop.Mobile.Shared")
  if ms != nil:
    if hook(methodAddr(ms, "set_HmdType", 1), cast[pointer](hookCaptureHmd),
            cast[ptr pointer](addr origSetHmdType)): inc ok
    if hook(methodAddr(ms, "set_FoveatedStreaming", 1), cast[pointer](hookCaptureFov),
            cast[ptr pointer](addr origSetFoveated)): inc ok
    if hook(methodAddr(ms, "set_MeasuredBandwidth", 1),
            cast[pointer](hookSetMeasuredBandwidth),
            cast[ptr pointer](addr origSetMeasuredBandwidth)): inc ok
    origSendReload = cast[VoidFn](methodAddr(ms, "SendSettingsReload", 0))
    if origSendReload == nil and pClassGetParent != nil:
      origSendReload = cast[VoidFn](findInherited(pClassGetParent(ms), "SendSettingsReload"))
  else:
    logE("SharedMobileSettings class not found")

  let ss = getClass("VirtualDesktop.Mobile.SharedStreamerSettings, VirtualDesktop.Mobile.Shared")
  if ss != nil:
    if hook(methodAddr(ss, "set_ActiveCodec", 1), cast[pointer](hookCaptureCodec),
            cast[ptr pointer](addr origSetActiveCodec)): inc ok
  else:
    logE("SharedStreamerSettings class not found")

  let jh = getClass("VirtualDesktop.Core.JsonHelper, VirtualDesktop.Core")
  if jh != nil:
    if hook(methodAddr(jh, "SerializerObject", 2), cast[pointer](hookSerializerObject),
            cast[ptr pointer](addr origSerializerObject)): inc ok
  else:
    logE("JsonHelper class not found")

  let st = getClass("VirtualDesktop.Mobile.SettingsTab, VirtualDesktop.Mobile")
  if st != nil:
    if hook(methodAddr(st, "OnMeasuredBandwidthChanged", 0),
            cast[pointer](hookSettingsMeasured),
            cast[ptr pointer](addr origSettingsMeasured)): inc ok
  else:
    logE("SettingsTab class not found")

  let ls = getClass("Xenko.UI.Controls.LimitSlider, Xenko.UI")
  if ls != nil:
    if hook(methodAddr(ls, "set_Limit", 1), cast[pointer](hookLimitSliderSetLimit),
            cast[ptr pointer](addr origLimitSliderSetLimit)): inc ok
  else:
    logE("LimitSlider class not found")

  logI("bitrate hooks=" & $ok & " scale=" & formatFloat(rateMul(), ffDecimal, 2))
  hx != nil and us != nil and ms != nil

# Forcing HasValidIdentity=true keeps locally discovered PCs merged in when the server is
# unreachable.
var
  origGetHasValidIdentity: GetBoolFn
  origSetHasValidIdentity: SetBoolFn
  origUserSettingsCtor: VoidFn
  gFieldUserHasValidIdentity: MonoField
  gUserSettingsDefault: pointer

proc captureUserSettings(self: pointer) =
  if self == nil: return
  if gUserSettingsDefault == nil:
    gUserSettingsDefault = self
    discard pin(self)
  if gFieldUserHasValidIdentity != nil:
    fieldSetBool(self, gFieldUserHasValidIdentity, true)

proc hookUserSettingsCtor(self: pointer) {.cdecl.} =
  captureUserSettings(self)
  if origUserSettingsCtor != nil: origUserSettingsCtor(self)

proc hookGetHasValidIdentity(self: pointer): bool {.cdecl.} =
  if not gForceLan.load():
    return if origGetHasValidIdentity != nil: origGetHasValidIdentity(self) else: false
  captureUserSettings(self)
  true

proc hookSetHasValidIdentity(self: pointer, v: bool) {.cdecl.} =
  var vv = v
  if gForceLan.load():
    captureUserSettings(self)
    vv = true
  if origSetHasValidIdentity != nil: origSetHasValidIdentity(self, vv)

proc installForceLanHooks(): bool =
  if not gForceLan.load():
    logI("forceLan off: hooks skipped")
    return true
  let mus = getClass("VirtualDesktop.Mobile.UserSettings, VirtualDesktop.Mobile")
  if mus == nil:
    logE("UserSettings class not found")
    return false
  if pClassGetField != nil:
    gFieldUserHasValidIdentity = pClassGetField(mus, "_hasValidIdentity")
  if hook(methodAddr(mus, "get_HasValidIdentity", 0),
          cast[pointer](hookGetHasValidIdentity),
          cast[ptr pointer](addr origGetHasValidIdentity)):
    logI("hooked UserSettings::get_HasValidIdentity")
  if hook(methodAddr(mus, "set_HasValidIdentity", 1),
          cast[pointer](hookSetHasValidIdentity),
          cast[ptr pointer](addr origSetHasValidIdentity)):
    logI("hooked UserSettings::set_HasValidIdentity")
  if hook(methodAddr(mus, ".ctor", 0), cast[pointer](hookUserSettingsCtor),
          cast[ptr pointer](addr origUserSettingsCtor)):
    logI("hooked UserSettings::.ctor")
  logI("forceLan: identity field=0x" &
       toLowerAscii(toHex(cast[uint64](gFieldUserHasValidIdentity), 16)).strip(
         trailing = false, chars = {'0'}))
  true

proc hookSerialize(x0, x1, x2, x3: pointer) {.cdecl.} =
  ## Watches font deserialisation for a full-coverage font to adopt.
  let slot = x1
  if origSerialize != nil: origSerialize(x0, x1, x2, x3)
  guard "Serialize":
    if serDone: return
    if serCount >= SER_CAP:
      serDone = true
      return
    inc serCount
    if slot == nil: return
    let o = cast[ptr MonoObject](slot)[]
    if o == nil or not isFontClass(o): return
    if glyphCount(o) >= FULL:
      markGood(o, "ser")
      if goodMapHas(14) and goodMapHas(16) and goodMapHas(20) and goodMapHas(24):
        serDone = true

proc tryCaptLoad(o: MonoObject) =
  guard "ContentManager::Load":
    if o == nil or not isFontClass(o): return
    if glyphCount(o) >= FULL: markGood(o, "load")

proc hookLoad3(x0, x1, x2, x3: pointer): MonoObject {.cdecl.} =
  result = if origLoad3 != nil: origLoad3(x0, x1, x2, x3) else: nil
  tryCaptLoad(result)

proc hookLoad2(x0, x1, x2: pointer): MonoObject {.cdecl.} =
  result = if origLoad2 != nil: origLoad2(x0, x1, x2) else: nil
  tryCaptLoad(result)

proc doSetupImpl() =
  if corlib() == nil: return

  # Install the font-independent hooks first, so they are not blocked by the text block's
  # early return; anything whose class will not resolve is retried on the next pass.
  if not gQualityTried.load() and installQualitySoundHooks(): gQualityTried.store(true)
  if not gBitrateTried.load() and installBitrateHooks(): gBitrateTried.store(true)
  if not gForceLanTried.load() and installForceLanHooks(): gForceLanTried.store(true)

  if not gMusicHooked.load() and not gMusicTried.load():
    gMusicTried.store(true)
    let ms = getClass("VirtualDesktop.Mobile.MusicSystem, VirtualDesktop.Mobile")
    if ms == nil:
      logE("MusicSystem class not found")
    elif hook(methodAddr(ms, "Play", 0), cast[pointer](hookMusicPlay),
              cast[ptr pointer](addr origMusicPlay)):
      gMusicHooked.store(true)
      logI("hooked MusicSystem::Play")
    else:
      logE("MusicSystem::Play hook failed")

  if not gTextHooked.load():
    let tb = getClass("Xenko.UI.Controls.TextBlock, Xenko.UI")
    if tb == nil: return
    let
      aSet = methodAddr(tb, "set_Text", 1)
      aSetF = methodAddr(tb, "set_Font", 1)
      aGetT = methodAddr(tb, "get_Text", 0)
    if aSet == nil or aSetF == nil: return
    getTextFn = cast[GetTextFn](aGetT)
    if not hook(aSet, cast[pointer](hookSetText), cast[ptr pointer](addr origSetText)):
      logE("set_Text hook failed")
    if not hook(aSetF, cast[pointer](hookSetFont), cast[ptr pointer](addr origSetFont)):
      logE("set_Font hook failed")
    let sf = getClass("Xenko.Graphics.SpriteFont, Xenko.Graphics")
    if sf != nil: getSizeFn = cast[GetSizeFn](methodAddr(sf, "get_Size", 0))
    let off = getClass("Xenko.Graphics.Font.OfflineRasterizedSpriteFont, Xenko.Graphics")
    if off != nil and pClassGetField != nil:
      gClsOff = off
      gDictField = pClassGetField(off, "CharacterToGlyph")
    gTextHooked.store(true)
    logI("hooked set_Text + set_Font")

  if not gSerHooked.load():
    let ser = getClass(
      "Xenko.Graphics.Font.OfflineRasterizedSpriteFontSerializer, Xenko.Graphics")
    if ser != nil and hook(methodAddr(ser, "Serialize", 3), cast[pointer](hookSerialize),
                           cast[ptr pointer](addr origSerialize)):
      gSerHooked.store(true)
      logI("hooked OfflineRasterizedSpriteFontSerializer::Serialize")

  if not gCmHooked.load():
    let cm = getClass(
      "Xenko.Core.Serialization.Contents.ContentManager, Xenko.Core.Serialization")
    if cm != nil:
      let
        aLoad3 = methodAddr(cm, "Load", 3)
        aLoad2 = methodAddr(cm, "Load", 2)
      if aLoad3 != nil and aLoad2 != nil and
         hook(aLoad3, cast[pointer](hookLoad3), cast[ptr pointer](addr origLoad3)) and
         hook(aLoad2, cast[pointer](hookLoad2), cast[ptr pointer](addr origLoad2)):
        gCmHooked.store(true)
        logI("hooked ContentManager::Load")

  if gTextHooked.load() and gSerHooked.load() and gCmHooked.load():
    gSetup.store(true)
    logI("setup done")

proc doSetup*() =
  if gSetup.load(): return
  # Re-entrancy guard: our own GetType call runs managed code, which trips ldstr again.
  var expected = false
  if not gInSetup.compareExchange(expected, true): return
  doSetupImpl()
  gInSetup.store(false)

# All of these run on a managed thread, which is the only place doSetup() is safe.
var gLd = 0

proc hookLdstr(a0, a1, a2, a3: pointer): MonoString {.cdecl.} =
  if a0 != nil: setDomain(a0)
  inc gLd
  if gLd <= 5 or gLd mod 500 == 0: logI("ldstr call #" & $gLd)
  if not gSetup.load() and gLd mod 20 == 2: doSetup()
  if origLdstr != nil: origLdstr(a0, a1, a2, a3) else: nil

var gObjNew = 0

proc hookObjNew(d: MonoDomain, k: MonoClass): MonoObject {.cdecl.} =
  ## Every `new X()` in managed code allocates through here. Unlike ldstr - interned, so a
  ## literal is only ever loaded once - this keeps firing in any actively running app, which
  ## makes it a far more reliable tick for a module that attached after startup.
  if d != nil: setDomain(d)
  inc gObjNew
  if gObjNew <= 5 or gObjNew mod 2000 == 0: logI("object_new call #" & $gObjNew)
  if not gSetup.load() and gObjNew mod 50 == 7: doSetup()
  if origObjNew != nil: origObjNew(d, k) else: nil

proc hookJitInit(name: cstring): MonoDomain {.cdecl.} =
  logI("jit_init('" & (if name == nil: "?" else: $name) & "') called")
  result = if origJitInit != nil: origJitInit(name) else: nil
  if result != nil: setDomain(result)
  if not gSetup.load(): doSetup()

proc hookJitExec(d: MonoDomain, asmv: pointer, argc: cint, argv: pointer): cint {.cdecl.} =
  logI("jit_exec called")
  if d != nil: setDomain(d)
  if not gSetup.load(): doSetup()
  if origJitExec != nil: origJitExec(d, asmv, argc, argv) else: -1

proc hookRunMain(asmv: pointer, argc: cint, argv: pointer): cint {.cdecl.} =
  logI("run_main called")
  if pGetRootDomain != nil: setDomain(pGetRootDomain())
  if not gSetup.load(): doSetup()
  if origRunMain != nil: origRunMain(asmv, argc, argv) else: -1

proc installTriggerHooks*(sym: proc(name: cstring): pointer {.cdecl, gcsafe.}) =
  ## ldstr is the one that matters; the rest are redundant nets that cost nothing. On this
  ## fully-AOT build they essentially never fire - AOT code branches straight between compiled
  ## methods rather than through Mono's generic entry points - so doSetup() has to run as soon
  ## as we attach rather than waiting for a tick.
  let ldstr = sym("mono_ldstr_checked")
  if ldstr == nil:
    logE("mono_ldstr_checked not found")
    return
  if not hook(ldstr, cast[pointer](hookLdstr), cast[ptr pointer](addr origLdstr)):
    logE("ldstr hook failed")
  hook(sym("mono_jit_exec"), cast[pointer](hookJitExec), cast[ptr pointer](addr origJitExec))
  hook(sym("mono_jit_init"), cast[pointer](hookJitInit), cast[ptr pointer](addr origJitInit))
  hook(sym("mono_runtime_run_main"), cast[pointer](hookRunMain),
       cast[ptr pointer](addr origRunMain))
  if not hook(sym("mono_object_new"), cast[pointer](hookObjNew),
              cast[ptr pointer](addr origObjNew)):
    logE("object_new hook failed")
  logI("mono hooked")
