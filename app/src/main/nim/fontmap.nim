## VD ships one font per size, and the ones it picks for most of the UI cover Latin only - so a
## translated string renders as boxes. The fonts that do carry full coverage pass through
## Xenko's serializer and content manager during startup, where `hooks/fonts` captures them;
## this is where they are kept and matched back to a size when a TextBlock needs one.
include nemohooks/features

import std/[tables, locks, math]
import nemohooks
import nemohooks/backends/mono

const FULL* = 1000 ## Glyph count we treat as full coverage.

type GetSizeFn* = proc(o: MonoObject): cfloat {.cdecl, gcsafe.}

var
  gClsOff*: MonoClass    ## OfflineRasterizedSpriteFont, the base of every font class we accept
  gDictField*: MonoField ## its CharacterToGlyph field
  getSizeFn*: GetSizeFn  ## SpriteFont::get_Size

var
  gGoodHandle: MonoGCHandle
  gGoodMap: Table[int, MonoGCHandle]
  gMapLock: Lock

gMapLock.initLock()

proc isFontClass*(o: MonoObject): bool =
  isSubclassOf(o, gClsOff)

proc fontSize*(f: MonoObject): float32 =
  if f == nil or getSizeFn == nil: 0'f32 else: float32(getSizeFn(f))

proc charToGlyph(font: MonoObject): MonoObject =
  if font == nil or gDictField == nil: return nil
  fieldGetPtr(font, gDictField)

proc glyphCount*(font: MonoObject): int =
  if font == nil or gDictField == nil or pFieldGetValue == nil or
     pClassGetMethod == nil: return -1
  let dict = charToGlyph(font)
  if dict == nil: return 0
  let dc = classOf(dict)
  if dc == nil: return -1
  let cm = pClassGetMethod(dc, "get_Count", 0)
  if cm == nil: return -1
  unboxInt32(invoke(cm, dict, nil))

proc hasWideChars*(s: ptr UncheckedArray[uint16], len: int): bool =
  for i in 0 ..< len:
    if s[i] > 0x2E7F'u16: return true
  false

proc displayWidth*(s: ptr UncheckedArray[uint16], len: int): int =
  result = 0
  for i in 0 ..< len:
    result += (if s[i] > 0x2E7F'u16: 2 else: 1)

var
  gContainsKey: MonoMethod
  gContainsKeyClass: MonoClass

proc dictHasKey(dict: MonoObject, unit: uint16): int =
  if dict == nil or pClassGetMethod == nil: return -1
  let dc = classOf(dict)
  if dc == nil: return -1
  if dc != gContainsKeyClass:
    gContainsKey = pClassGetMethod(dc, "ContainsKey", 1)
    gContainsKeyClass = dc
  let m = gContainsKey
  if m == nil: return -1
  var key = int32(unit)
  var args {.noinit.}: array[1, pointer]
  args[0] = addr key
  unboxBool(invoke(m, dict, cast[ptr UncheckedArray[pointer]](addr args[0])))

proc fontCovers*(font: MonoObject, s: ptr UncheckedArray[uint16], len: int): bool =
  if len <= 0: return true
  if not isFontClass(font): return not hasWideChars(s, len)
  let dict = charToGlyph(font)
  if dict == nil: return not hasWideChars(s, len)
  var asked: seq[uint16] = @[]
  for i in 0 ..< len:
    let u = s[i]
    if u < 0x80'u16: continue
    if u in asked: continue
    asked.add u
    case dictHasKey(dict, u)
    of 0: return false
    of 1: discard
    else: return not hasWideChars(s, len)
  true

proc markGood*(f: MonoObject, tag: string) =
  if f == nil: return
  let g = glyphCount(f)
  if g < FULL: return
  let sz = fontSize(f)
  let k = int(round(sz))
  if gGoodHandle == 0'u32:
    gGoodHandle = pin(f)
    logI("[F] goodFont(" & tag & ") size=" & $sz & " glyphs=" & $g)
  withLock gMapLock:
    if not gGoodMap.hasKey(k): gGoodMap[k] = pin(f)

proc goodMapHas*(k: int): bool =
  withLock gMapLock:
    result = gGoodMap.hasKey(k)

proc goodFont*(): MonoObject = moved(gGoodHandle)

proc pickReplacement*(size: float32): MonoObject =
  var h: MonoGCHandle = 0
  withLock gMapLock:
    if gGoodHandle == 0'u32: return nil
    let r = int(round(size))
    if r == 30 or r == 32:
      if gGoodMap.hasKey(r):
        h = gGoodMap.getOrDefault(r)
      else:
        var best = gGoodHandle
        var bd = high(int)
        for k, v in gGoodMap:
          let d = abs(k - r)
          if d < bd:
            bd = d
            best = v
        h = best
    else:
      var mk = low(int)
      for k, v in gGoodMap:
        if k != 32 and k > mk:
          mk = k
          h = v
      if h == 0'u32:
        h = if gGoodMap.hasKey(32): gGoodMap.getOrDefault(32) else: gGoodHandle
  moved(h)
