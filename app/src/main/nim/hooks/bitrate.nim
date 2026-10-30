include nemohooks/features

import std/[atomics, strutils]
import nemohooks
import nemohooks/backends/mono

type
  MinMax1Fn = proc(a: int32): int32 {.cdecl, gcsafe.}
  MinMax3Fn = proc(a, b, c: int32): int32 {.cdecl, gcsafe.}
  CalcBitrate2Fn = proc(a: int32, t: cfloat): int32 {.cdecl, gcsafe.}
  BitrateStr2Fn = proc(a: int32, t: cfloat): MonoString {.cdecl, gcsafe.}
  SetInt1Fn = proc(self: pointer, v: int32) {.cdecl, gcsafe.}
  SetFloat1Fn = proc(self: pointer, v: cfloat) {.cdecl, gcsafe.}
  SerializerObjectFn = proc(obj, writer: pointer) {.cdecl, gcsafe.}

  DeskMode = enum
    dmUnknown, dmTable, dmOuter

  BitrateFeature* = ref object of Feature
    scale*: Atomic[float32]
    extend*: Atomic[bool]
    unlock*: Atomic[bool]

    maxDesk, maxVR, desktopBitrate, desktopBitrateString: Hook
    setDesktopLimit, setVRLimit: Hook
    setHmdType, setCodec, setFoveated, setMeasuredBandwidth: Hook
    serializerObject, settingsMeasured, limitSliderSetLimit: Hook

    minDesk, minVR: MinMax1Fn ## never hooked, only read to compute k
    sendReload, userSendReload: VoidFn
    userSettingsClass: MonoClass
    desktopLimitField, vrLimitField: MonoField
    mobileSettings, userSettings: pointer

    deskMode: Atomic[int]
    speedtestDone: Atomic[bool]
    hmd, codec, fov: Atomic[int32]

var bitrateFeature* = BitrateFeature(name: "bitrate")

var
  tProbeHit {.threadvar.}: bool
  tInString {.threadvar.}: bool
  tLimitCtx {.threadvar.}: bool

proc rateMul(): float32 =
  let s = bitrateFeature.scale.load()
  if bitrateFeature.extend.load() and s > 0'f32: s else: 1'f32

proc scaleMax(v: int32): int32 =
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
  let orig = origAs[MinMax1Fn](bitrateFeature.maxDesk)
  if hmd < 0 or bitrateFeature.minDesk == nil or orig == nil: return rateMul()
  kCalc(float32(bitrateFeature.minDesk(hmd)), float32(orig(hmd)))

proc kVRFor(hmd, codec, fov: int32): float32 =
  let orig = origAs[MinMax3Fn](bitrateFeature.maxVR)
  if hmd < 0 or codec < 0 or bitrateFeature.minVR == nil or orig == nil: return rateMul()
  kCalc(float32(bitrateFeature.minVR(hmd)), float32(orig(hmd, codec, fov)))

proc kDesktop(): float32 = kDesktopFor(bitrateFeature.hmd.load())
proc kVR(): float32 = kVRFor(bitrateFeature.hmd.load(), bitrateFeature.codec.load(),
    bitrateFeature.fov.load())

proc mode(): DeskMode = DeskMode(bitrateFeature.deskMode.load())
proc setMode(m: DeskMode) = bitrateFeature.deskMode.store(int(m))

proc hookMaxDesk(hmd: int32): int32 {.cdecl.} =
  let orig = origAs[MinMax1Fn](bitrateFeature.maxDesk)
  if mode() == dmOuter:
    return if orig != nil: orig(hmd) else: 0
  tProbeHit = true
  scaleMax(if orig != nil: orig(hmd) else: 0)

proc hookMaxVR(hmd, codec, fov: int32): int32 {.cdecl.} =
  let orig = origAs[MinMax3Fn](bitrateFeature.maxVR)
  scaleMax(if orig != nil: orig(hmd, codec, fov) else: 0)

proc hookDesktopBitrate(hmd: int32, t: cfloat): int32 {.cdecl.} =
  let orig = origAs[CalcBitrate2Fn](bitrateFeature.desktopBitrate)
  if orig == nil: return 0
  if tInString: return orig(hmd, t)
  case mode()
  of dmTable: return orig(hmd, t)
  of dmOuter: return orig(hmd, cfloat(t * kDesktopFor(hmd)))
  of dmUnknown:
    tProbeHit = false
    let r = orig(hmd, t)
    if tProbeHit:
      setMode(dmTable)
      logI("bitrate desktop: table hook ACTIVE (direct)")
      return r
    setMode(dmOuter)
    logI("bitrate desktop: table inlined -> outer hook")
    return orig(hmd, cfloat(t * kDesktopFor(hmd)))

proc hookDesktopBitrateString(hmd: int32, t: cfloat): MonoString {.cdecl.} =
  let orig = origAs[BitrateStr2Fn](bitrateFeature.desktopBitrateString)
  if orig == nil: return nil
  if mode() != dmOuter: return orig(hmd, t)
  tInString = true
  result = orig(hmd, cfloat(t * kDesktopFor(hmd)))
  tInString = false

proc hookSettingsMeasured(self: pointer) {.cdecl.} =
  tLimitCtx = true
  let orig = origAs[VoidFn](bitrateFeature.settingsMeasured)
  if orig != nil: orig(self)
  tLimitCtx = false

proc hookLimitSliderSetLimit(self: pointer, v: cfloat) {.cdecl.} =
  var value = v
  if mode() == dmOuter and tLimitCtx:
    let k = kDesktop()
    if k > 1'f32: value = cfloat(value / k)
  let orig = origAs[SetFloat1Fn](bitrateFeature.limitSliderSetLimit)
  if orig != nil: orig(self, value)

proc captureMobile(self: pointer) =
  if self != nil and bitrateFeature.mobileSettings == nil:
    discard pin(self)
    bitrateFeature.mobileSettings = self

proc hookCaptureHmd(self: pointer, v: int32) {.cdecl.} =
  bitrateFeature.hmd.store(v)
  captureMobile(self)
  let orig = origAs[SetInt1Fn](bitrateFeature.setHmdType)
  if orig != nil: orig(self, v)

proc hookCaptureCodec(self: pointer, v: int32) {.cdecl.} =
  bitrateFeature.codec.store(v)
  captureMobile(self)
  let orig = origAs[SetInt1Fn](bitrateFeature.setCodec)
  if orig != nil: orig(self, v)

proc hookCaptureFov(self: pointer, v: int32) {.cdecl.} =
  bitrateFeature.fov.store(v)
  captureMobile(self)
  let orig = origAs[SetInt1Fn](bitrateFeature.setFoveated)
  if orig != nil: orig(self, v)

proc sanitiseLimit(v: cfloat): cfloat =
  if v != v: 0'f32
  elif v < 0'f32: 0'f32
  else: v

proc rememberUserSettings(self: pointer) =
  if bitrateFeature.userSettings == nil:
    let h = pin(self)
    if h != 0'u32: bitrateFeature.userSettings = moved(h)

proc resendFullPacket(pinned: pointer) =
  if rateMul() > 1'f32 and bitrateFeature.speedtestDone.load():
    if bitrateFeature.userSendReload != nil: bitrateFeature.userSendReload(pinned)
    if bitrateFeature.mobileSettings != nil and bitrateFeature.sendReload != nil:
      bitrateFeature.sendReload(bitrateFeature.mobileSettings)

proc hookSetDesktopLimit(self: pointer, v: cfloat) {.cdecl.} =
  let orig = origAs[SetFloat1Fn](bitrateFeature.setDesktopLimit)
  if orig == nil: return
  rememberUserSettings(self)
  let h = pin(self)
  let p = if h != 0'u32: moved(h) else: self
  orig(p, sanitiseLimit(v))
  resendFullPacket(p)
  unpin(h)

proc hookSetVRLimit(self: pointer, v: cfloat) {.cdecl.} =
  let orig = origAs[SetFloat1Fn](bitrateFeature.setVRLimit)
  if orig == nil: return
  rememberUserSettings(self)
  let h = pin(self)
  let p = if h != 0'u32: moved(h) else: self
  orig(p, sanitiseLimit(v))
  resendFullPacket(p)
  unpin(h)

proc hookSerializerObject(obj, writer: pointer) {.cdecl.} =
  let orig = origAs[SerializerObjectFn](bitrateFeature.serializerObject)
  if orig == nil: return
  let isUserSettings = obj != nil and bitrateFeature.userSettingsClass != nil and
                       pObjGetClass != nil and pObjGetClass(obj) == bitrateFeature.userSettingsClass
  if bitrateFeature.userSettings == nil and isUserSettings:
    rememberUserSettings(obj)
  if rateMul() <= 1'f32 or not isUserSettings or
     bitrateFeature.desktopLimitField == nil or bitrateFeature.vrLimitField == nil:
    orig(obj, writer)
    return
  let h = pin(obj)
  let p = if h != 0'u32: moved(h) else: obj
  let
    d0 = fieldGetF32(p, bitrateFeature.desktopLimitField)
    v0 = fieldGetF32(p, bitrateFeature.vrLimitField)
  fieldSetF32(p, bitrateFeature.desktopLimitField, d0 * kDesktop())
  fieldSetF32(p, bitrateFeature.vrLimitField, v0 * kVR())
  orig(p, writer)
  fieldSetF32(p, bitrateFeature.desktopLimitField, d0)
  fieldSetF32(p, bitrateFeature.vrLimitField, v0)
  unpin(h)

proc hookSetMeasuredBandwidth(self: pointer, v: int32) {.cdecl.} =
  captureMobile(self)
  let firstReal = v > 0'i32 and not bitrateFeature.speedtestDone.load()
  var value = v
  if bitrateFeature.unlock.load() and (bitrateFeature.speedtestDone.load() or firstReal):
    value = high(int32)
  if firstReal: bitrateFeature.speedtestDone.store(true)
  let orig = origAs[SetInt1Fn](bitrateFeature.setMeasuredBandwidth)
  if orig != nil: orig(self, value)
  if firstReal and bitrateFeature.unlock.load():
    if bitrateFeature.sendReload != nil: bitrateFeature.sendReload(self)
    if bitrateFeature.userSendReload != nil and bitrateFeature.userSettings != nil:
      bitrateFeature.userSendReload(bitrateFeature.userSettings)

const
  HMD_EXT = "Xenko.VR.HmdResolutionTypeExtensions, VirtualDesktop.Mobile.Shared"
  SHARED_USER = "VirtualDesktop.Mobile.SharedUserSettings, VirtualDesktop.Mobile.Shared"
  SHARED_MOBILE = "VirtualDesktop.Mobile.SharedMobileSettings, VirtualDesktop.Mobile.Shared"
  SHARED_STREAMER = "VirtualDesktop.Mobile.SharedStreamerSettings, VirtualDesktop.Mobile.Shared"
  JSON_HELPER = "VirtualDesktop.Core.JsonHelper, VirtualDesktop.Core"
  SETTINGS_TAB = "VirtualDesktop.Mobile.SettingsTab, VirtualDesktop.Mobile"
  LIMIT_SLIDER = "Xenko.UI.Controls.LimitSlider, Xenko.UI"

bitrateFeature.maxDesk = newHook(HMD_EXT, "GetMaxDesktopBitrate", 1, asPointer(hookMaxDesk))
bitrateFeature.maxVR = newHook(HMD_EXT, "GetMaxVRBitrate", 3, asPointer(hookMaxVR))
bitrateFeature.desktopBitrate = newHook(HMD_EXT, "GetDesktopBitrate", 2,
                                 asPointer(hookDesktopBitrate))
bitrateFeature.desktopBitrateString = newHook(HMD_EXT, "GetDesktopBitrateString", 2,
                                       asPointer(hookDesktopBitrateString))
bitrateFeature.setDesktopLimit = newHook(SHARED_USER, "set_DesktopBitrateLimit", 1,
                                  asPointer(hookSetDesktopLimit))
bitrateFeature.setVRLimit = newHook(SHARED_USER, "set_VRBitrateLimit", 1,
                             asPointer(hookSetVRLimit))
bitrateFeature.setHmdType = newHook(SHARED_MOBILE, "set_HmdType", 1, asPointer(hookCaptureHmd))
bitrateFeature.setFoveated = newHook(SHARED_MOBILE, "set_FoveatedStreaming", 1,
                              asPointer(hookCaptureFov))
bitrateFeature.setMeasuredBandwidth = newHook(SHARED_MOBILE, "set_MeasuredBandwidth", 1,
                                       asPointer(hookSetMeasuredBandwidth))
bitrateFeature.setCodec = newHook(SHARED_STREAMER, "set_ActiveCodec", 1,
                           asPointer(hookCaptureCodec))
bitrateFeature.serializerObject = newHook(JSON_HELPER, "SerializerObject", 2,
                                   asPointer(hookSerializerObject))
bitrateFeature.settingsMeasured = newHook(SETTINGS_TAB, "OnMeasuredBandwidthChanged", 0,
                                   asPointer(hookSettingsMeasured))
bitrateFeature.limitSliderSetLimit = newHook(LIMIT_SLIDER, "set_Limit", 1,
                                      asPointer(hookLimitSliderSetLimit))

method install*(f: BitrateFeature): bool =
  var ok = 0

  let hx = getClass(HMD_EXT)
  if hx != nil:
    f.minDesk = asProc[MinMax1Fn](methodAddr(hx, "GetMinDesktopBitrate", 1))
    f.minVR = asProc[MinMax1Fn](methodAddr(hx, "GetMinVRBitrate", 1))
    for h in [f.maxDesk, f.maxVR, f.desktopBitrate, f.desktopBitrateString]:
      if h.install(hx): inc ok
  else:
    logE("HmdResolutionTypeExtensions class not found")

  let us = getClass(SHARED_USER)
  if us != nil:
    if pClassGetField != nil:
      f.desktopLimitField = pClassGetField(us, "_desktopBitrateLimit")
      f.vrLimitField = pClassGetField(us, "_vrBitrateLimit")
    for h in [f.setDesktopLimit, f.setVRLimit]:
      if h.install(us): inc ok
  else:
    logE("SharedUserSettings class not found")
  f.userSettingsClass = us
  if us != nil and pClassGetParent != nil:
    f.userSendReload = asProc[VoidFn](findInherited(pClassGetParent(us), "SendSettingsReload"))

  let ms = getClass(SHARED_MOBILE)
  if ms != nil:
    for h in [f.setHmdType, f.setFoveated, f.setMeasuredBandwidth]:
      if h.install(ms): inc ok
    f.sendReload = asProc[VoidFn](methodAddr(ms, "SendSettingsReload", 0))
    if f.sendReload == nil and pClassGetParent != nil:
      f.sendReload = asProc[VoidFn](findInherited(pClassGetParent(ms), "SendSettingsReload"))
  else:
    logE("SharedMobileSettings class not found")

  if f.setCodec.install(): inc ok
  if f.serializerObject.install(): inc ok
  if f.settingsMeasured.install(): inc ok
  if f.limitSliderSetLimit.install(): inc ok

  logI("bitrate hooks=" & $ok & " scale=" & formatFloat(rateMul(), ffDecimal, 2))
  hx != nil and us != nil and ms != nil
