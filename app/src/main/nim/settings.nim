## The settings the in-VD page drives, each one bound to the atomic its feature already reads.
##
## This exists so `hooks/section` stays UI code: it asks for a value to show and hands back the
## one the user set, without knowing which feature owns it. Values are carried as float32 in
## every case - a toggle is 0 or 1 - because that is what both of VD's controls report.
##
## Nothing here persists. A change takes effect at once and is lost when VD restarts; the
## companion app is still what writes the preferences read at startup.
include nemohooks/features

## Nimony has no Atomic[T] of its own; ours lives in the library's compat module.
when defined(nimony):
  import nemohooks/compat

import std/atomics
import hooks/[sound, bitrate, fit, forcelan]

type
  Setting* = enum
    stNone ## A row with no setting behind it: a header, a description, an unwired button.
    stFit
    stNoPerfSound
    stBitrateExtend
    stBitrateUnlock
    stForceLan
    stMusicVolume
    stBitrateScale
    stFitPad

proc bounds*(s: Setting): (float32, float32) =
  ## The range a slider row is given. These match the clamps the JNI setters apply, so a value
  ## set here cannot differ from one the companion app could have sent.
  case s
  of stMusicVolume: (0'f32, 1'f32)
  of stBitrateScale: (1'f32, 3'f32)
  of stFitPad: (0'f32, 64'f32)
  else: (0'f32, 1'f32)

proc readValue*(s: Setting): float32 =
  case s
  of stFit: (if fitFeature.enabled.load(): 1'f32 else: 0'f32)
  of stNoPerfSound: (if cueSoundsFeature.enabled.load(): 1'f32 else: 0'f32)
  of stBitrateExtend: (if bitrateFeature.extend.load(): 1'f32 else: 0'f32)
  of stBitrateUnlock: (if bitrateFeature.unlock.load(): 1'f32 else: 0'f32)
  of stForceLan: (if forceLanFeature.enabled.load(): 1'f32 else: 0'f32)
  of stMusicVolume: musicFeature.volume.load()
  of stBitrateScale: bitrateFeature.scale.load()
  of stFitPad: fitFeature.pad.load()
  of stNone: 0'f32

proc writeValue*(s: Setting, v: float32) =
  let on = v >= 0.5'f32
  case s
  of stFit: fitFeature.enabled.store(on)
  of stNoPerfSound: cueSoundsFeature.enabled.store(on)
  of stBitrateExtend: bitrateFeature.extend.store(on)
  of stBitrateUnlock: bitrateFeature.unlock.store(on)
  of stForceLan: forceLanFeature.enabled.store(on)
  of stMusicVolume: musicFeature.volume.store(v)
  of stBitrateScale: bitrateFeature.scale.store(v)
  of stFitPad: fitFeature.pad.store(v)
  of stNone: discard

proc describe*(s: Setting, v: float32): string =
  ## For the log line a change writes, so a headset session can be read back from logcat.
  case s
  of stMusicVolume, stBitrateScale, stFitPad: $v
  of stNone: "-"
  else: (if v >= 0.5'f32: "on" else: "off")
