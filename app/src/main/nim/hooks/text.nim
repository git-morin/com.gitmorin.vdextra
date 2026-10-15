import ../vdlog, ../mono, hook

type
  SetTextFn = proc(tb: pointer, s: MonoString) {.cdecl, gcsafe.}
  SetFontFn = proc(tb: pointer, f: MonoObject) {.cdecl, gcsafe.}
  GetTextFn = proc(tb: pointer): MonoString {.cdecl, gcsafe.}

  TextFeature* = ref object of Feature
    setText, setFont: Hook
    getText: GetTextFn

const TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"

var textFeature* = TextFeature(name: "text", gates: true, blocking: true)

proc hookSetText(tb: pointer, s: MonoString) {.cdecl.} =
  var value = s
  guard "set_Text":
    let t = translate(s)
    if t != nil: value = t
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
        needsFull = hasCjk(monoStrChars(s), monoStrLen(s))
      if needsFull and glyphCount(cur) < FULL:
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

  let sf = getClass("Xenko.Graphics.SpriteFont, Xenko.Graphics")
  if sf != nil: getSizeFn = cast[GetSizeFn](methodAddr(sf, "get_Size", 0))

  let off = getClass("Xenko.Graphics.Font.OfflineRasterizedSpriteFont, Xenko.Graphics")
  if off != nil and pClassGetField != nil:
    gClsOff = off
    gDictField = pClassGetField(off, "CharacterToGlyph")

  logI("hooked set_Text + set_Font")
  true
