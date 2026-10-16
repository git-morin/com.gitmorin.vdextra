import std/atomics
import ../vdlog, ../mono, hook

const CUE_NAMES = ["PlayPotato", "PlayUltra", "PlayGodlike", "PlayMonster",
                   "PlayRampage", "PlayUnstoppable", "PlayHolyShit"]

type
  SetFloat1Fn = proc(self: pointer, v: cfloat) {.cdecl, gcsafe.}
  Void2Fn = proc(self, state: pointer) {.cdecl, gcsafe.}

  MusicFeature* = ref object of Feature
    volume*: Atomic[float32]
    custom*: Atomic[bool]
    state*: Atomic[int] ## 0 unknown, 1 playing, 2 paused; polled by the Java player
    play, playCb, fadeOut, pauseNow, resume, onTimer: Hook
    musicField, sourceField: MonoField
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

proc hookMusicPlay(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](musicFeature.play)
  if orig != nil: orig(self)
  guard "music play":
    applyVolume(self)
    musicFeature.state.store(1)

proc hookMusicPlayCb(self, state: pointer) {.cdecl.} =
  let orig = origAs[Void2Fn](musicFeature.playCb)
  if orig != nil: orig(self, state)
  guard "music play cb":
    applyVolume(self)
    musicFeature.state.store(1)

proc hookMusicFadeOut(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](musicFeature.fadeOut)
  if orig != nil: orig(self)
  musicFeature.state.store(2)

proc hookMusicPauseNow(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](musicFeature.pauseNow)
  if orig != nil: orig(self)
  musicFeature.state.store(2)

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
    musicFeature.state.store(1)

template defCue(idx: static int, name: untyped) =
  proc name(self: pointer) {.cdecl.} =
    if cueSoundsFeature.enabled.load() and (cueSoundsFeature.mask.load() and (1 shl idx)) != 0: return
    let orig = origAs[VoidFn](cueSoundsFeature.cues[idx])
    if orig != nil: orig(self)

defCue(0, cue0)
defCue(1, cue1)
defCue(2, cue2)
defCue(3, cue3)
defCue(4, cue4)
defCue(5, cue5)
defCue(6, cue6)

const MUSIC_SYSTEM = "VirtualDesktop.Mobile.MusicSystem, VirtualDesktop.Mobile"

musicFeature.play = newHook(MUSIC_SYSTEM, "Play", 0, cast[pointer](hookMusicPlay))
musicFeature.playCb = newHook(MUSIC_SYSTEM, "Play", 1, cast[pointer](hookMusicPlayCb))
musicFeature.fadeOut = newHook(MUSIC_SYSTEM, "FadeOut", 0, cast[pointer](hookMusicFadeOut))
musicFeature.pauseNow = newHook(MUSIC_SYSTEM, "PauseNow", 0, cast[pointer](hookMusicPauseNow))
musicFeature.resume = newHook(MUSIC_SYSTEM, "Resume", 0, cast[pointer](hookMusicResume))
musicFeature.onTimer = newHook(MUSIC_SYSTEM, "OnTimer", 1, cast[pointer](hookMusicOnTimer))

block:
  let repls = [cast[pointer](cue0), cast[pointer](cue1), cast[pointer](cue2),
               cast[pointer](cue3), cast[pointer](cue4), cast[pointer](cue5),
               cast[pointer](cue6)]
  for i, n in CUE_NAMES:
    cueSoundsFeature.cues[i] = newHook("VirtualDesktop.Mobile.SoundSystem, VirtualDesktop.Mobile",
                                n, 0, repls[i])

method install*(f: MusicFeature): bool =
  let cls = getClass(MUSIC_SYSTEM)
  if cls == nil:
    logE("MusicSystem class not found")
    return false
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
  f.setVolume = cast[SetFloat1Fn](methodAddr(si, "set_Volume", 1))
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
  for h in [f.playCb, f.fadeOut, f.pauseNow, f.resume, f.onTimer]: h.install(cls)
  logI("hooked MusicSystem::Play, music volume=" & $f.volume.load())
  true

method install*(f: CueSoundsFeature): bool =
  let cls = getClass("VirtualDesktop.Mobile.SoundSystem, VirtualDesktop.Mobile")
  if cls == nil:
    logE("SoundSystem class not found")
    return false
  var ok = 0
  for h in f.cues:
    if h.install(cls): inc ok
  logI("hooked quality sounds: " & $ok & "/" & $CUE_NAMES.len & " mask=" & $f.mask.load())
  true
