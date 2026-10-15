import std/atomics
import ../vdlog, ../mono, hook

const CUE_NAMES = ["PlayPotato", "PlayUltra", "PlayGodlike", "PlayMonster",
                   "PlayRampage", "PlayUnstoppable", "PlayHolyShit"]

type
  MusicFeature* = ref object of Feature
    disabled*: Atomic[bool]
    play: Hook

  CueSoundsFeature* = ref object of Feature
    enabled*: Atomic[bool]
    mask*: Atomic[int]
    cues: array[CUE_NAMES.len, Hook]

var
  musicFeature* = MusicFeature(name: "music", once: true)
  cueSoundsFeature* = CueSoundsFeature(name: "cue sounds")

proc hookMusicPlay(self: pointer) {.cdecl.} =
  if musicFeature.disabled.load(): return
  let orig = origAs[VoidFn](musicFeature.play)
  if orig != nil: orig(self)

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

musicFeature.play = newHook("VirtualDesktop.Mobile.MusicSystem, VirtualDesktop.Mobile",
                     "Play", 0, cast[pointer](hookMusicPlay))

block:
  let repls = [cast[pointer](cue0), cast[pointer](cue1), cast[pointer](cue2),
               cast[pointer](cue3), cast[pointer](cue4), cast[pointer](cue5),
               cast[pointer](cue6)]
  for i, n in CUE_NAMES:
    cueSoundsFeature.cues[i] = newHook("VirtualDesktop.Mobile.SoundSystem, VirtualDesktop.Mobile",
                                n, 0, repls[i])

method install*(f: MusicFeature): bool =
  let cls = getClass("VirtualDesktop.Mobile.MusicSystem, VirtualDesktop.Mobile")
  if cls == nil:
    logE("MusicSystem class not found")
    return false
  if not f.play.install(cls):
    logE("MusicSystem::Play hook failed")
    return false
  logI("hooked MusicSystem::Play")
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
