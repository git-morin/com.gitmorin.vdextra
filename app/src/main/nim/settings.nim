## The settings the in-VD page drives, each one bound to the atomic its feature already reads.
##
## This exists so `hooks/section` stays UI code: it asks for a value to show and hands back the
## one the user set, without knowing which feature owns it. Values are carried as float32 in
## every case - a toggle is 0 or 1 - because that is what both of VD's controls report.
##
## A change takes effect at once and is also written to VD's data directory, so it survives a
## restart without the companion app. `conf` does the writing; MainModule reads the file back
## at startup and feeds it through the JNI setters it already calls.
include nemohooks/features

when defined(nimony):
  import nemohooks/compat

import std/[atomics, strutils]
import nemohooks/log
import conf
import hooks/[sound, bitrate, forcelan]

type
  Setting* = enum
    stNone
    stNoPerfSound
    stBitrateExtend
    stBitrateUnlock
    stForceLan
    stMusicVolume
    stBitrateScale

proc bounds*(s: Setting): (float32, float32) =
  case s
  of stMusicVolume: (0'f32, 1'f32)
  of stBitrateScale: (1'f32, 3'f32)
  else: (0'f32, 1'f32)

proc readValue*(s: Setting): float32 =
  case s
  of stNoPerfSound: (if cueSoundsFeature.enabled.load(): 1'f32 else: 0'f32)
  of stBitrateExtend: (if bitrateFeature.extend.load(): 1'f32 else: 0'f32)
  of stBitrateUnlock: (if bitrateFeature.unlock.load(): 1'f32 else: 0'f32)
  of stForceLan: (if forceLanFeature.enabled.load(): 1'f32 else: 0'f32)
  of stMusicVolume: musicFeature.volume.load()
  of stBitrateScale: bitrateFeature.scale.load()
  of stNone: 0'f32

proc writeValue*(s: Setting, v: float32) =
  let on = v >= 0.5'f32
  case s
  of stNoPerfSound: cueSoundsFeature.enabled.store(on)
  of stBitrateExtend: bitrateFeature.extend.store(on)
  of stBitrateUnlock: bitrateFeature.unlock.store(on)
  of stForceLan: forceLanFeature.enabled.store(on)
  of stMusicVolume: musicFeature.volume.store(v)
  of stBitrateScale: bitrateFeature.scale.store(v)
  of stNone: discard

proc format*(s: Setting, v: float32): string =
  case s
  of stMusicVolume: $int(v * 100'f32 + 0.5'f32) & "%"
  of stBitrateScale: formatFloat(v, ffDecimal, 1) & "x"
  else: ""

proc key*(s: Setting): string =
  case s
  of stNoPerfSound: "disable_quality_sound"
  of stBitrateExtend: "bitrate_extend"
  of stBitrateUnlock: "bitrate_unlock"
  of stForceLan: "force_lan"
  of stMusicVolume: "music_volume"
  of stBitrateScale: "bitrate_scale"
  of stNone: ""

const SCALE = 1000'f32

const PERSISTED = [stNoPerfSound, stBitrateExtend, stBitrateUnlock, stForceLan,
                   stMusicVolume, stBitrateScale]

proc serialise(): string =
  result = "# vdextra settings, written from the in-VD page; values are x1000\n"
  for s in PERSISTED:
    result.add key(s) & "=" & $int(readValue(s) * SCALE + 0.5'f32) & "\n"

var
  dirty = false
  idleFrames = 0

const SETTLE_FRAMES = 30

proc markDirty*() =
  dirty = true
  idleFrames = 0

proc flush*() =
  if not dirty: return
  dirty = false
  if writeConf(serialise()): logI("settings saved")

proc flushIfSettled*() =
  if not dirty: return
  inc idleFrames
  if idleFrames >= SETTLE_FRAMES: flush()

proc describe*(s: Setting, v: float32): string =
  case s
  of stMusicVolume, stBitrateScale: $v
  of stNone: "-"
  else: (if v >= 0.5'f32: "on" else: "off")
