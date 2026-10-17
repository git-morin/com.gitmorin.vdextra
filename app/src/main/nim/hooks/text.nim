import std/atomics
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
    setTextSize: SetF32Fn
    setWrapText: SetBoolFn
    fit*: Atomic[bool]
    fitFloor*: Atomic[float32]

const TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"

var textFeature* = TextFeature(name: "text", gates: true, blocking: true)

textFeature.fit.store(true)
textFeature.fitFloor.store(0.75'f32)

# A translation wider than the string VD sized its layout against overflows by exactly that
# ratio, so shrinking the text by the inverse puts it back inside. Only strings the dictionary
# actually replaced are touched: VD's own text keeps whatever size it chose.
proc fitText(tb: pointer, src, trans: MonoString) =
  if not textFeature.fit.load(): return
  if textFeature.setTextSize == nil or textFeature.getFont == nil: return

  let sw = displayWidth(monoStrChars(src), monoStrLen(src))
  let tw = displayWidth(monoStrChars(trans), monoStrLen(trans))
  if sw <= 0 or tw <= sw: return

  let floorV = textFeature.fitFloor.load()
  var ratio = float32(sw) / float32(tw)
  let clamped = ratio < floorV
  if clamped: ratio = floorV

  let natural = fontSize(textFeature.getFont(tb))
  if natural <= 0'f32: return
  let target = natural * ratio

  # Shrink only, never grow: a block VD deliberately set smaller keeps its size, and setting
  # the same string again settles on the same target instead of shrinking a second time.
  if textFeature.getTextSize != nil:
    let cur = float32(textFeature.getTextSize(tb))
    if cur > 0'f32 and target >= cur: return
  textFeature.setTextSize(tb, cfloat(target))

  # At the floor the shrink alone cannot recover the width, so let it wrap as well.
  if clamped and textFeature.setWrapText != nil: textFeature.setWrapText(tb, true)

proc hookSetText(tb: pointer, s: MonoString) {.cdecl.} =
  var value = s
  guard "set_Text":
    let t = translate(s)
    if t != nil:
      value = t
      fitText(tb, s, t)
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
  f.setTextSize = cast[SetF32Fn](methodAddr(tb, "set_TextSize", 1))
  f.setWrapText = cast[SetBoolFn](methodAddr(tb, "set_WrapText", 1))
  logI("textFit members: font=" & $(f.getFont != nil) & " getTextSize=" &
       $(f.getTextSize != nil) & " setTextSize=" & $(f.setTextSize != nil) &
       " wrap=" & $(f.setWrapText != nil))

  let sf = getClass("Xenko.Graphics.SpriteFont, Xenko.Graphics")
  if sf != nil: getSizeFn = cast[GetSizeFn](methodAddr(sf, "get_Size", 0))

  let off = getClass("Xenko.Graphics.Font.OfflineRasterizedSpriteFont, Xenko.Graphics")
  if off != nil and pClassGetField != nil:
    gClsOff = off
    gDictField = pClassGetField(off, "CharacterToGlyph")

  logI("hooked set_Text + set_Font")
  true
