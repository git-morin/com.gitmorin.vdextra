## The module's JNI surface: the registry of features nemohooks installs, and the setters the
## Kotlin side calls to push settings across.
include nemohooks/features

import std/[strutils, atomics]
import nemohooks
import nemohooks/backends/mono
import dict
import hooks/[sound, text, fonts, forcelan, bitrate, fit, section]

useBackend(monoBackend())

# Order is load-bearing: font-independent features first so a missing TextBlock cannot
# stop them, and text before the font-capture features, which need what it resolves.
registerFeatures(@[
  Feature(cueSoundsFeature), Feature(bitrateFeature), Feature(forceLanFeature), Feature(
      musicFeature),
  Feature(textFeature), Feature(fontSerializerFeature), Feature(contentLoadFeature),
  Feature(fitFeature), Feature(sectionFeature)
])

proc Java_com_gitmorin_vdextra_MainModule_nativeInit(env, thiz: pointer)
    {.exportc, cdecl, dynlib.} =
  startRuntimePoll()

proc Java_com_gitmorin_vdextra_MainModule_nativeCheckMono(env, thiz: pointer): bool
    {.exportc, cdecl, dynlib.} =
  logI("nativeCheckMono called from the Java initInternal hook")
  attachNow()

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

## Polled by the Java player, which owns the audio whenever a custom track is playing: the
## volume VD's own music system is given goes to zero in that case, so the slider can only
## reach the sound through here.
proc Java_com_gitmorin_vdextra_MainModule_nativeMusicVolume(
    env, cls: pointer): cfloat {.exportc, cdecl, dynlib.} =
  cfloat(musicFeature.volume.load())

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

## Reached through init.c rather than as a JNI entry point of its own, because converting the
## jstring needs the env; the dictionary arrives the same way.
proc vdSetVersion(v: cstring) {.exportc: "vdSetVersion", cdecl, dynlib.} =
  setVersion($v)
  logI("version=" & $v)

proc vdDictLogCount() {.exportc: "vdDictLogCount", cdecl, dynlib.} =
  logI("dict=" & $dictLen())
