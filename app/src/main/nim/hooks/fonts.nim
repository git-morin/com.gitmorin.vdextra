include nemohooks/features

import nemohooks
import nemohooks/backends/mono
import ../fontmap

const SER_CAP = 40

type
  SerializeFn = proc(x0, x1, x2, x3: pointer) {.cdecl, gcsafe.}
  Load3Fn = proc(x0, x1, x2, x3: pointer): MonoObject {.cdecl, gcsafe.}
  Load2Fn = proc(x0, x1, x2: pointer): MonoObject {.cdecl, gcsafe.}

  FontSerializerFeature* = ref object of Feature
    serialize: Hook
    seen: int
    satisfied: bool

  ContentLoadFeature* = ref object of Feature
    load3, load2: Hook

var
  fontSerializerFeature* = FontSerializerFeature(name: "font serializer", gates: true)
  contentLoadFeature* = ContentLoadFeature(name: "content load", gates: true)

proc hookSerialize(x0, x1, x2, x3: pointer) {.cdecl.} =
  let slot = x1
  let orig = origAs[SerializeFn](fontSerializerFeature.serialize)
  if orig != nil: orig(x0, x1, x2, x3)
  guard "Serialize":
    if fontSerializerFeature.satisfied: return
    if fontSerializerFeature.seen >= SER_CAP:
      fontSerializerFeature.satisfied = true
      return
    inc fontSerializerFeature.seen
    if slot == nil: return
    let o = cast[ptr MonoObject](slot)[]
    if o == nil or not isFontClass(o): return
    if glyphCount(o) >= FULL:
      markGood(o, "ser")
      if goodMapHas(14) and goodMapHas(16) and goodMapHas(20) and goodMapHas(24):
        fontSerializerFeature.satisfied = true

proc capture(o: MonoObject) =
  guard "ContentManager::Load":
    if o == nil or not isFontClass(o): return
    if glyphCount(o) >= FULL: markGood(o, "load")

proc hookLoad3(x0, x1, x2, x3: pointer): MonoObject {.cdecl.} =
  let orig = origAs[Load3Fn](contentLoadFeature.load3)
  result = if orig != nil: orig(x0, x1, x2, x3) else: nil
  capture(result)

proc hookLoad2(x0, x1, x2: pointer): MonoObject {.cdecl.} =
  let orig = origAs[Load2Fn](contentLoadFeature.load2)
  result = if orig != nil: orig(x0, x1, x2) else: nil
  capture(result)

fontSerializerFeature.serialize = newHook(
  "Xenko.Graphics.Font.OfflineRasterizedSpriteFontSerializer, Xenko.Graphics",
  "Serialize", 3, asPointer(hookSerialize))

const CONTENT_MANAGER = "Xenko.Core.Serialization.Contents.ContentManager, Xenko.Core.Serialization"
contentLoadFeature.load3 = newHook(CONTENT_MANAGER, "Load", 3, asPointer(hookLoad3))
contentLoadFeature.load2 = newHook(CONTENT_MANAGER, "Load", 2, asPointer(hookLoad2))

method install*(f: FontSerializerFeature): bool =
  let cls = getClass("Xenko.Graphics.Font.OfflineRasterizedSpriteFontSerializer, Xenko.Graphics")
  if cls == nil or not f.serialize.install(cls): return false
  logI("hooked OfflineRasterizedSpriteFontSerializer::Serialize")
  true

method install*(f: ContentLoadFeature): bool =
  let cls = getClass(CONTENT_MANAGER)
  if cls == nil: return false
  if methodAddr(cls, "Load", 3) == nil or methodAddr(cls, "Load", 2) == nil: return false
  if not f.load3.install(cls) or not f.load2.install(cls): return false
  logI("hooked ContentManager::Load")
  true
