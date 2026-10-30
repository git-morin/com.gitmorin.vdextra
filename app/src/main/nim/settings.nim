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

## Nimony has no Atomic[T] of its own; ours lives in the library's compat module.
when defined(nimony):
  import nemohooks/compat

import std/[atomics, strutils]
import nemohooks/log
import conf
import hooks/[sound, bitrate, forcelan]

type
  Setting* = enum
    stNone ## A row with no setting behind it: a header or a description.
    stNoPerfSound
    stBitrateExtend
    stBitrateUnlock
    stForceLan
    stMusicVolume
    stBitrateScale

proc bounds*(s: Setting): (float32, float32) =
  ## The range a slider row is given. These match the clamps the JNI setters apply, so a value
  ## set here cannot differ from one the companion app could have sent.
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
  ## What the value label beside a slider's track shows. VD keeps one per slider row and fills
  ## it from an event handler, which a clone does not carry - so a slider that is not given its
  ## text here moves but reads as whatever VD's template said.
  case s
  of stMusicVolume: $int(v * 100'f32 + 0.5'f32) & "%"
  of stBitrateScale: formatFloat(v, ffDecimal, 1) & "x"
  else: ""

## The key each setting is stored under. These are the companion app's PrefKeys names, so one
## file can be read straight into the same preferences rather than needing a mapping.
proc key*(s: Setting): string =
  case s
  of stNoPerfSound: "disable_quality_sound"
  of stBitrateExtend: "bitrate_extend"
  of stBitrateUnlock: "bitrate_unlock"
  of stForceLan: "force_lan"
  of stMusicVolume: "music_volume"
  of stBitrateScale: "bitrate_scale"
  of stNone: ""

## Values go out as thousandths of their real value, so the file holds only integers and the
## reader needs no float parsing - and no decimal separator that a locale could move.
const SCALE = 1000'f32

## Exactly the settings the in-VD page owns, listed rather than iterated over the enum: Nimony
## has no `items` for a typedesc, and naming them keeps this a decision.
##
## A setting the page cannot change must stay out of this file. The reader prefers the file over
## the companion app's preferences, so persisting one the app still owns would pin it to whatever
## was saved here and silently ignore every later change made in the app.
const PERSISTED = [stNoPerfSound, stBitrateExtend, stBitrateUnlock, stForceLan,
                   stMusicVolume, stBitrateScale]

proc serialise(): string =
  result = "# vdextra settings, written from the in-VD page; values are x1000\n"
  for s in PERSISTED:
    result.add key(s) & "=" & $int(readValue(s) * SCALE + 0.5'f32) & "\n"

var
  dirty = false
  idleFrames = 0

## A drag changes the value on most frames, so a write is held back until it settles. 30 frames
## is a third of a second at VD's 90fps - short enough to survive the panel being closed right
## after, long enough that one drag is one write rather than ninety.
const SETTLE_FRAMES = 30

proc markDirty*() =
  dirty = true
  idleFrames = 0

proc flush*() =
  if not dirty: return
  dirty = false
  if writeConf(serialise()): logI("settings saved")

## Called every panel tick: writes once the value has stopped moving.
proc flushIfSettled*() =
  if not dirty: return
  inc idleFrames
  if idleFrames >= SETTLE_FRAMES: flush()

proc describe*(s: Setting, v: float32): string =
  ## For the log line a change writes, so a headset session can be read back from logcat.
  case s
  of stMusicVolume, stBitrateScale: $v
  of stNone: "-"
  else: (if v >= 0.5'f32: "on" else: "off")
