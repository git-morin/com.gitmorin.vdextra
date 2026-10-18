import std/[atomics, strutils]
import ../vdlog, ../mono, hook

type
  SetTextFn = proc(tb: pointer, s: MonoString) {.cdecl, gcsafe.}
  SetFontFn = proc(tb: pointer, f: MonoObject) {.cdecl, gcsafe.}
  GetTextFn = proc(tb: pointer): MonoString {.cdecl, gcsafe.}
  GetFontFn = proc(tb: pointer): MonoObject {.cdecl, gcsafe.}
  GetF32Fn = proc(tb: pointer): cfloat {.cdecl, gcsafe.}
  SetF32Fn = proc(tb: pointer, v: cfloat) {.cdecl, gcsafe.}
  SetBoolFn = proc(tb: pointer, v: bool) {.cdecl, gcsafe.}

  TextFeature* = ref object of Feature
    setText, setFont: Hook
    getText: GetTextFn
    getFont: GetFontFn
    getTextSize: GetF32Fn
    getWidth, getMinWidth, getMaxWidth: GetF32Fn
    setMinWidth: SetF32Fn
    setWrapText: SetBoolFn
    room*: Atomic[bool]
    roomCap*: Atomic[float32]
    reports: int

const TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"

var textFeature* = TextFeature(name: "text", gates: true, blocking: true)

textFeature.room.store(true)
textFeature.roomCap.store(1.5'f32)

const REPORT_CAP = 8 ## labels to describe before going quiet

# The font is often assigned after the text, so get_Font alone would leave most labels with no
# size to work from. TextSize is the next best, and the captured full font is the last resort.
proc textPointSize(tb: pointer): float32 =
  if textFeature.getFont != nil:
    let s = fontSize(textFeature.getFont(tb))
    if s > 0'f32: return s
  if textFeature.getTextSize != nil:
    let s = float32(textFeature.getTextSize(tb))
    if s > 0'f32: return s
  fontSize(goodFont())

proc report(what: string) =
  if textFeature.reports >= REPORT_CAP: return
  inc textFeature.reports
  logI("[R] " & what)

# Widens the room the layout gives a translated label instead of squeezing the text into it.
# MinimumWidth feeds Measure, and Xenko clamps an explicit Width to it, so the parent has to
# allocate the space either way.
#
# The width VD already chose is the baseline: it was adequate for the source string, so scaling
# it by how much wider the translation is lands on the room actually needed. Estimating pixels
# from the font size instead was the earlier mistake - unanchored, it overshot badly.
proc giveRoom(tb: pointer, src, trans: MonoString) =
  if not textFeature.room.load() or textFeature.setMinWidth == nil: return
  if textFeature.getWidth == nil: return

  let sw = displayWidth(monoStrChars(src), monoStrLen(src))
  let tw = displayWidth(monoStrChars(trans), monoStrLen(trans))
  if sw <= 0 or tw <= sw: return # same width or narrower: nothing to correct

  # An explicit Width reads back as a number; auto reads back NaN, which fails this compare.
  # An auto label already grows to its content, so the clipping is higher up the tree and
  # widening this element achieves nothing.
  let w = float32(textFeature.getWidth(tb))
  if w != w or w <= 0'f32:
    report("auto width, skipped: size=" & formatFloat(textPointSize(tb), ffDecimal, 1) &
           " src=" & $sw & " trans=" & $tw)
    return

  var ratio = float32(tw) / float32(sw)
  let cap = textFeature.roomCap.load()
  if ratio > cap: ratio = cap
  var need = w * ratio

  # Never past an explicit ceiling the layout set for this element.
  if textFeature.getMaxWidth != nil:
    let maxW = float32(textFeature.getMaxWidth(tb))
    if maxW == maxW and maxW > 0'f32 and need > maxW: need = maxW

  # Raised only, never lowered, so reassigning the same string settles instead of compounding.
  # Width is never written here, which is what keeps the baseline stable across calls.
  if textFeature.getMinWidth != nil:
    let cur = float32(textFeature.getMinWidth(tb))
    if cur == cur and cur >= need: return

  report("w=" & formatFloat(w, ffDecimal, 1) & " src=" & $sw & " trans=" & $tw &
         " ratio=" & formatFloat(ratio, ffDecimal, 2) & " -> minw=" &
         formatFloat(need, ffDecimal, 1))
  textFeature.setMinWidth(tb, cfloat(need))

proc hookSetText(tb: pointer, s: MonoString) {.cdecl.} =
  var value = s
  guard "set_Text":
    let t = translate(s)
    if t != nil:
      value = t
      giveRoom(tb, s, t)
  let orig = origAs[SetTextFn](textFeature.setText)
  if orig != nil: orig(tb, value)

proc hookSetFont(tb: pointer, newFont: MonoObject) {.cdecl.} =
  var cur = newFont
  guard "set_Font":
    let good = goodFont()
    if good != nil and cur != nil and cur != good:
      var needsFull = false
      if textFeature.getText != nil:
        let s = textFeature.getText(tb)
        needsFull = not fontCovers(cur, monoStrChars(s), monoStrLen(s))
      if needsFull:
        let repl = pickReplacement(fontSize(cur))
        if repl != nil and repl != cur: cur = repl
  let orig = origAs[SetFontFn](textFeature.setFont)
  if orig != nil: orig(tb, cur)

textFeature.setText = newHook(TEXT_BLOCK, "set_Text", 1, cast[pointer](hookSetText))
textFeature.setFont = newHook(TEXT_BLOCK, "set_Font", 1, cast[pointer](hookSetFont))

method install*(f: TextFeature): bool =
  let tb = getClass(TEXT_BLOCK)
  if tb == nil: return false
  if methodAddr(tb, "set_Text", 1) == nil or methodAddr(tb, "set_Font", 1) == nil: return false

  f.getText = cast[GetTextFn](methodAddr(tb, "get_Text", 0))
  if not f.setText.install(tb): logE("set_Text hook failed")
  if not f.setFont.install(tb): logE("set_Font hook failed")

  f.getFont = cast[GetFontFn](methodAddr(tb, "get_Font", 0))
  f.getTextSize = cast[GetF32Fn](methodAddr(tb, "get_TextSize", 0))
  f.setWrapText = cast[SetBoolFn](methodAddr(tb, "set_WrapText", 1))

  # MinimumWidth is declared on UIElement, and mono_class_get_method_from_name does not walk
  # bases, so resolve it there rather than on TextBlock.
  let ui = getClass("Xenko.UI.UIElement, Xenko.UI")
  if ui != nil:
    f.getWidth = cast[GetF32Fn](methodAddr(ui, "get_Width", 0))
    f.getMinWidth = cast[GetF32Fn](methodAddr(ui, "get_MinimumWidth", 0))
    f.getMaxWidth = cast[GetF32Fn](methodAddr(ui, "get_MaximumWidth", 0))
    f.setMinWidth = cast[SetF32Fn](methodAddr(ui, "set_MinimumWidth", 1))
  logI("textRoom members: getWidth=" & $(f.getWidth != nil) & " getMinWidth=" &
       $(f.getMinWidth != nil) & " getMaxWidth=" & $(f.getMaxWidth != nil) &
       " setMinWidth=" & $(f.setMinWidth != nil) & " uiElement=" & $(ui != nil))

  let sf = getClass("Xenko.Graphics.SpriteFont, Xenko.Graphics")
  if sf != nil: getSizeFn = cast[GetSizeFn](methodAddr(sf, "get_Size", 0))

  let off = getClass("Xenko.Graphics.Font.OfflineRasterizedSpriteFont, Xenko.Graphics")
  if off != nil and pClassGetField != nil:
    gClsOff = off
    gDictField = pClassGetField(off, "CharacterToGlyph")

  logI("hooked set_Text + set_Font")
  true
