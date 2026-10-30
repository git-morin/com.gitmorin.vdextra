include nemohooks/features

import std/atomics
import nemohooks
import nemohooks/backends/mono

const CUE_NAMES = ["PlayPotato", "PlayUltra", "PlayGodlike", "PlayMonster",
                   "PlayRampage", "PlayUnstoppable", "PlayHolyShit"]

type
  SetFloat1Fn = proc(self: pointer, v: cfloat) {.cdecl, gcsafe.}
  Void2Fn = proc(self, state: pointer) {.cdecl, gcsafe.}
  Void3Fn = proc(self, sender, args: pointer) {.cdecl, gcsafe.}

  MusicFeature* = ref object of Feature
    volume*: Atomic[float32]
    custom*: Atomic[bool]
    state*: Atomic[int] ## 0 unknown, 1 playing, 2 paused; polled by the Java player
    play, pause, fadeOut, pauseNow, resume, onTimer, connChanged: Hook
    musicField, sourceField: MonoField
    cls: MonoClass
    setVolume: SetFloat1Fn

  CueSoundsFeature* = ref object of Feature
    enabled*: Atomic[bool]
    mask*: Atomic[int]
    cues: array[CUE_NAMES.len, Hook]

var
  musicFeature* = MusicFeature(name: "music", once: true)
  cueSoundsFeature* = CueSoundsFeature(name: "cue sounds")

musicFeature.volume.store(1'f32)

proc applyVolume(self: pointer) =
  if self == nil or musicFeature.setVolume == nil or musicFeature.musicField == nil: return
  if pObjGetClass == nil or musicFeature.cls == nil: return
  if pObjGetClass(self) != musicFeature.cls: return

  let v = if musicFeature.custom.load(): 0'f32 else: musicFeature.volume.load()
  if v >= 1'f32: return
  let inst = fieldGetPtr(self, musicFeature.musicField)
  if inst == nil: return
  if musicFeature.sourceField == nil: return
  if fieldGetPtr(inst, musicFeature.sourceField) == nil: return
  musicFeature.setVolume(inst, cfloat(v))

proc setState(s: int, why: string) =
  if musicFeature.state.load() == s: return
  musicFeature.state.store(s)
  logI("music " & why & " -> " & (if s == 1: "playing" else: "paused"))

proc hookMusicPlay(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](musicFeature.play)
  if orig != nil: orig(self)
  guard "music play":
    applyVolume(self)
    setState(1, "Play")

proc hookMusicPause(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](musicFeature.pause)
  if orig != nil: orig(self)
  setState(2, "Pause")

proc hookMusicFadeOut(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](musicFeature.fadeOut)
  if orig != nil: orig(self)
  setState(2, "FadeOut")

proc hookMusicPauseNow(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](musicFeature.pauseNow)
  if orig != nil: orig(self)
  setState(2, "PauseNow")

proc hookMusicConnChanged(self, sender, args: pointer) {.cdecl.} =
  let orig = origAs[Void3Fn](musicFeature.connChanged)
  if orig != nil: orig(self, sender, args)
  logI("music OnIsConnectedChanged")

proc hookMusicOnTimer(self, state: pointer) {.cdecl.} =
  let orig = origAs[Void2Fn](musicFeature.onTimer)
  if orig != nil: orig(self, state)
  guard "music timer": applyVolume(self)

proc hookMusicResume(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](musicFeature.resume)
  if orig != nil: orig(self)
  guard "music resume":
    applyVolume(self)
    setState(1, "Resume")

proc cueBody(idx: int, self: pointer) =
  if cueSoundsFeature.enabled.load() and (cueSoundsFeature.mask.load() and (1 shl idx)) != 0: return
  let orig = origAs[VoidFn](cueSoundsFeature.cues[idx])
  if orig != nil: orig(self)

proc cue0(self: pointer) {.cdecl.} = cueBody(0, self)
proc cue1(self: pointer) {.cdecl.} = cueBody(1, self)
proc cue2(self: pointer) {.cdecl.} = cueBody(2, self)
proc cue3(self: pointer) {.cdecl.} = cueBody(3, self)
proc cue4(self: pointer) {.cdecl.} = cueBody(4, self)
proc cue5(self: pointer) {.cdecl.} = cueBody(5, self)
proc cue6(self: pointer) {.cdecl.} = cueBody(6, self)

const MUSIC_SYSTEM = "VirtualDesktop.Mobile.MusicSystem, VirtualDesktop.Mobile"

musicFeature.play = newHook(MUSIC_SYSTEM, "Play", 0, asPointer(hookMusicPlay))
musicFeature.pause = newHook(MUSIC_SYSTEM, "Pause", 0, asPointer(hookMusicPause))
musicFeature.fadeOut = newHook(MUSIC_SYSTEM, "FadeOut", 0, asPointer(hookMusicFadeOut))
musicFeature.connChanged = newHook(MUSIC_SYSTEM, "OnIsConnectedChanged", 2,
                            asPointer(hookMusicConnChanged))
musicFeature.pauseNow = newHook(MUSIC_SYSTEM, "PauseNow", 0, asPointer(hookMusicPauseNow))
musicFeature.resume = newHook(MUSIC_SYSTEM, "Resume", 0, asPointer(hookMusicResume))
musicFeature.onTimer = newHook(MUSIC_SYSTEM, "OnTimer", 1, asPointer(hookMusicOnTimer))

block:
  let repls = [asPointer(cue0), asPointer(cue1), asPointer(cue2),
               asPointer(cue3), asPointer(cue4), asPointer(cue5),
               asPointer(cue6)]
  for i, n in CUE_NAMES:
    cueSoundsFeature.cues[i] = newHook("VirtualDesktop.Mobile.SoundSystem, VirtualDesktop.Mobile",
                                n, 0, repls[i])

method install*(f: MusicFeature): bool =
  let cls = getClass(MUSIC_SYSTEM)
  if cls == nil:
    logE("MusicSystem class not found")
    return false
  f.cls = cls
  if pClassGetField != nil: f.musicField = pClassGetField(cls, "_music")
  if f.musicField == nil:
    logE("MusicSystem::_music not found")
    return false
  let si = getClass("Xenko.Audio.SoundInstance, Xenko.Audio")
  if si == nil:
    logE("SoundInstance class not found")
    return false
  f.setVolume = asProc[SetFloat1Fn](methodAddr(si, "set_Volume", 1))
  if f.setVolume == nil:
    logE("SoundInstance::set_Volume not found")
    return false
  if pClassGetField != nil: f.sourceField = pClassGetField(si, "Source")
  if f.sourceField == nil:
    logE("SoundInstance::Source not found, leaving music volume alone")
    return false
  if not f.play.install(cls):
    logE("MusicSystem::Play hook failed")
    return false
  f.pause.install(cls)
  f.fadeOut.install(cls)
  f.pauseNow.install(cls)
  f.resume.install(cls)
  f.onTimer.install(cls)
  f.connChanged.install(cls)
  logI("hooked MusicSystem::Play, music volume=" & $f.volume.load())
  true

method install*(f: CueSoundsFeature): bool =
  let cls = getClass("VirtualDesktop.Mobile.SoundSystem, VirtualDesktop.Mobile")
  if cls == nil:
    logE("SoundSystem class not found")
    return false
  var ok = 0
  for i in 0 ..< f.cues.len:
    if f.cues[i].install(cls): inc ok
  logI("hooked quality sounds: " & $ok & "/" & $CUE_NAMES.len & " mask=" & $f.mask.load())
  true
