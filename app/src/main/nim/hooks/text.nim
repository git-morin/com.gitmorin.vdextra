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
    getMinWidth: GetF32Fn
    setMinWidth: SetF32Fn
    setWrapText: SetBoolFn
    room*: Atomic[bool]
    roomFactor*: Atomic[float32]

const TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"

var textFeature* = TextFeature(name: "text", gates: true, blocking: true)

textFeature.room.store(true)
textFeature.roomFactor.store(0.5'f32)

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

# Widens the room the layout gives a translated label instead of squeezing the text into it.
# MinimumWidth feeds Measure, and Xenko clamps an explicit Width to it, so the parent has to
# allocate the space either way. A glyph advance averages about half the em and displayWidth
# already counts a full-width glyph as two, hence the factor.
proc giveRoom(tb: pointer, trans: MonoString) =
  if not textFeature.room.load() or textFeature.setMinWidth == nil: return

  let size = textPointSize(tb)
  if size <= 0'f32: return
  let need = float32(displayWidth(monoStrChars(trans), monoStrLen(trans))) * size *
             textFeature.roomFactor.load()
  if need <= 0'f32: return

  # Raised only, never lowered, so reassigning the same string settles instead of compounding.
  # An unset MinimumWidth reads back NaN, which the self-comparison rejects.
  if textFeature.getMinWidth != nil:
    let cur = float32(textFeature.getMinWidth(tb))
    if cur == cur and cur >= need: return
  textFeature.setMinWidth(tb, cfloat(need))

proc hookSetText(tb: pointer, s: MonoString) {.cdecl.} =
  var value = s
  guard "set_Text":
    let t = translate(s)
    if t != nil:
      value = t
      giveRoom(tb, t)
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
    f.getMinWidth = cast[GetF32Fn](methodAddr(ui, "get_MinimumWidth", 0))
    f.setMinWidth = cast[SetF32Fn](methodAddr(ui, "set_MinimumWidth", 1))
  logI("textRoom members: font=" & $(f.getFont != nil) & " textSize=" &
       $(f.getTextSize != nil) & " getMinWidth=" & $(f.getMinWidth != nil) &
       " setMinWidth=" & $(f.setMinWidth != nil) & " wrap=" & $(f.setWrapText != nil) &
       " uiElement=" & $(ui != nil))

  let sf = getClass("Xenko.Graphics.SpriteFont, Xenko.Graphics")
  if sf != nil: getSizeFn = cast[GetSizeFn](methodAddr(sf, "get_Size", 0))

  let off = getClass("Xenko.Graphics.Font.OfflineRasterizedSpriteFont, Xenko.Graphics")
  if off != nil and pClassGetField != nil:
    gClsOff = off
    gDictField = pClassGetField(off, "CharacterToGlyph")

  logI("hooked set_Text + set_Font")
  true
