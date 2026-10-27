## Raw interop; see the nimohooks module docs for why these two features are on.
when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "assumeSync".}

import std/atomics
import nimohooks

type
  GetBoolFn = proc(self: pointer): bool {.cdecl, gcsafe.}
  SetBoolFn = proc(self: pointer, v: bool) {.cdecl, gcsafe.}

  ForceLanFeature* = ref object of Feature
    enabled*: Atomic[bool]
    getIdentity, setIdentity, ctor: Hook
    identityField: MonoField
    settings: pointer

const USER_SETTINGS = "VirtualDesktop.Mobile.UserSettings, VirtualDesktop.Mobile"

var forceLanFeature* = ForceLanFeature(name: "forceLan")

proc capture(self: pointer) =
  if self == nil: return
  if forceLanFeature.settings == nil:
    forceLanFeature.settings = self
    discard pin(self)
  if forceLanFeature.identityField != nil:
    fieldSetBool(self, forceLanFeature.identityField, true)

proc hookCtor(self: pointer) {.cdecl.} =
  capture(self)
  let orig = origAs[VoidFn](forceLanFeature.ctor)
  if orig != nil: orig(self)

proc hookGetIdentity(self: pointer): bool {.cdecl.} =
  if not forceLanFeature.enabled.load():
    let orig = origAs[GetBoolFn](forceLanFeature.getIdentity)
    return if orig != nil: orig(self) else: false
  capture(self)
  true

proc hookSetIdentity(self: pointer, v: bool) {.cdecl.} =
  var value = v
  if forceLanFeature.enabled.load():
    capture(self)
    value = true
  let orig = origAs[SetBoolFn](forceLanFeature.setIdentity)
  if orig != nil: orig(self, value)

forceLanFeature.getIdentity = newHook(USER_SETTINGS, "get_HasValidIdentity", 0,
                               asPointer(hookGetIdentity))
forceLanFeature.setIdentity = newHook(USER_SETTINGS, "set_HasValidIdentity", 1,
                               asPointer(hookSetIdentity))
forceLanFeature.ctor = newHook(USER_SETTINGS, ".ctor", 0, asPointer(hookCtor))

method install*(f: ForceLanFeature): bool =
  if not f.enabled.load():
    logI("forceLan off: hooks skipped")
    return true
  let cls = getClass(USER_SETTINGS)
  if cls == nil:
    logE("UserSettings class not found")
    return false
  if pClassGetField != nil:
    f.identityField = pClassGetField(cls, "_hasValidIdentity")
  if f.getIdentity.install(cls): logI("hooked UserSettings::get_HasValidIdentity")
  if f.setIdentity.install(cls): logI("hooked UserSettings::set_HasValidIdentity")
  if f.ctor.install(cls): logI("hooked UserSettings::.ctor")
  logI("forceLan: identity field=" & hex(f.identityField))
  true
