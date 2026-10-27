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

  ## Nimony has no Atomic[T] of its own; ours lives in compat.
  import ../compat

import std/atomics
import ../vdlog, ../mono, hook

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

# Atomics zero-initialise, and zero here would mute the music the hook is meant to leave
# alone if MainModule never reaches nativeSetMusicVolume.
musicFeature.volume.store(1'f32)

# _music is a fresh SoundInstance per track, and Play() only queues the load, so the volume
# has to be re-applied every time rather than set once.
proc applyVolume(self: pointer) =
  if self == nil or musicFeature.setVolume == nil or musicFeature.musicField == nil: return
  # Only trust self once it really is a MusicSystem: a hooked method that turns out to be
  # static hands us its argument instead, and reading _music off that is a wild pointer.
  if pObjGetClass == nil or musicFeature.cls == nil: return
  if pObjGetClass(self) != musicFeature.cls: return
  # A custom track plays over VD's, so VD's own goes silent rather than being suppressed:
  # leaving its Play intact keeps _music alive, so its own fade and pause stay safe.
  let v = if musicFeature.custom.load(): 0'f32 else: musicFeature.volume.load()
  if v >= 1'f32: return # full scale means VD's own level, not a forced 1.0
  let inst = fieldGetPtr(self, musicFeature.musicField)
  if inst == nil: return
  # set_Volume goes straight to xnAudioSourceSetGain with no null check of its own, so the
  # native source must already exist; it is still null while the track is being loaded.
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

# Logged, not acted on: the handler carries no new value, so Play/Pause stay the signal. It is
# here to show in the log which path a connect actually takes.
proc hookMusicConnChanged(self, sender, args: pointer) {.cdecl.} =
  let orig = origAs[Void3Fn](musicFeature.connChanged)
  if orig != nil: orig(self, sender, args)
  logI("music OnIsConnectedChanged")

# The music timer is the retry clock: Play lands before the source exists, so the volume is
# re-attempted here until it sticks.
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

## Each cue needs its own address for Dobby to hook, but they differ only by index.
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
  # the setter, never the volume field: Xenko pushes gain down to the native audio layer,
  # so writing the field alone changes nothing audible.
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
  # Spelled out rather than looped over an array literal: gathering these ref fields into one
  # crashes nimony 0.6.3 (finalir.nim: `n.stmtKind in {StmtsS, ScopeS}`).
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
