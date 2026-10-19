import std/atomics
import ../vdlog, ../mono, hook, loadcontent

## Feasibility spike: add a VDExtra entry to the control panel's left navigation.
##
## The nav is a StackPanel of Buttons, each wrapping a TextBlock, so an entry is just one more
## Button appended to it. The work has to happen inside LoadContent because VD measures this
## layout exactly once - an element added later is never laid out, which is what made the
## injected scroller invisible to VD's bounds and depth assignment.
##
## Styling is copied from an existing nav button rather than invented: its DependencyProperties
## carry cell placement, and its TextBlock carries the font and size the nav uses.

const
  UI_ELEMENT = "Xenko.UI.UIElement, Xenko.UI"
  BUTTON = "Xenko.UI.Controls.Button, Xenko.UI"
  TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"
  CONTENT_CONTROL = "Xenko.UI.Controls.ContentControl, Xenko.UI"

  SECTION_NAME = "VDEXTRA"

  ## The nav column measures 300 wide; the content column beside it is 980.
  NAV_WIDTH_MIN = 250.0
  NAV_WIDTH_MAX = 350.0

  ## A container holding this many children is the entry stack rather than a header or spacer.
  MIN_NAV_ENTRIES = 4

type
  GetObjFn = proc(self: pointer): pointer {.cdecl, gcsafe.}
  SetObjFn = proc(self: pointer, v: pointer) {.cdecl, gcsafe.}
  AddFn = proc(self: pointer, item: pointer) {.cdecl, gcsafe.}
  SetStrFn = proc(self: pointer, s: MonoString) {.cdecl, gcsafe.}
  SetF32Fn = proc(self: pointer, v: cfloat) {.cdecl, gcsafe.}
  GetF32Fn = proc(self: pointer): cfloat {.cdecl, gcsafe.}

  SectionFeature* = ref object of Feature
    enabled*: Atomic[bool]

    offGridMain, offDepProps: int
    buttonClass, textClass: MonoClass
    getVisualChildren: GetObjFn
    setContent: SetObjFn
    setText: SetStrFn
    setTextSize: SetF32Fn
    getTextSize: GetF32Fn
    setFont: SetObjFn
    getFont: GetObjFn
    applied: bool

var sectionFeature* = SectionFeature(name: "vdextra section")

sectionFeature.enabled.store(true)

const
  LIST_ITEMS = 16
  LIST_SIZE = 24
  ARRAY_DATA = 32
  F_RENDER = 104

proc childCount(coll: pointer): int =
  if coll == nil: 0
  else: int(cast[ptr int32](cast[uint64](coll) + uint64(LIST_SIZE))[])

proc childAt(coll: pointer, i: int): pointer =
  let items = cast[ptr pointer](cast[uint64](coll) + uint64(LIST_ITEMS))[]
  if items == nil: return nil
  cast[ptr pointer](cast[uint64](items) + uint64(ARRAY_DATA + i * 8))[]

proc renderWidth(o: pointer): float32 =
  if o == nil: 0.0
  else: cast[ptr float32](cast[uint64](o) + uint64(F_RENDER))[]

## Add lives on the collection's own generic type, so it is resolved by walking up from the
## instance rather than from a class name known ahead of time.
proc resolveAdd(coll: pointer): AddFn =
  var k = classOf(coll)
  for _ in 0 ..< 6:
    if k == nil: break
    let a = methodAddr(k, "Add", 1)
    if a != nil: return cast[AddFn](a)
    k = pClassGetParent(k)
  nil

proc firstTextBlock(el: pointer, depth: int): pointer =
  let f = sectionFeature
  if el == nil or depth > 4: return nil
  if classOf(el) == f.textClass: return el
  let kids = f.getVisualChildren(el)
  let n = childCount(kids)
  if n <= 0 or n > 512: return nil
  for i in 0 ..< n:
    let hit = firstTextBlock(childAt(kids, i), depth + 1)
    if hit != nil: return hit
  nil

## The nav column is the narrow one; the content column beside it is three times wider.
proc findNavStack(gridMain: pointer): pointer =
  let f = sectionFeature
  let cols = f.getVisualChildren(gridMain)
  let n = childCount(cols)
  if n <= 0 or n > 512: return nil
  for i in 0 ..< n:
    let col = childAt(cols, i)
    if col == nil: continue
    let w = renderWidth(col)
    if w < NAV_WIDTH_MIN or w > NAV_WIDTH_MAX: continue
    let inner = f.getVisualChildren(col)
    let m = childCount(inner)
    for j in 0 ..< m:
      let cand = childAt(inner, j)
      if cand == nil: continue
      if childCount(f.getVisualChildren(cand)) >= MIN_NAV_ENTRIES: return cand
  nil

proc buildEntry(model: pointer): pointer =
  let f = sectionFeature
  let btn = newInstance(f.buttonClass)
  if btn == nil: return nil
  discard pin(btn)

  let label = newInstance(f.textClass)
  if label == nil: return nil
  discard pin(label)

  let name = makeMono(SECTION_NAME)
  if name == nil: return nil
  f.setText(label, name)

  # Match the existing entries so the new one is not styled differently.
  let modelText = firstTextBlock(model, 0)
  if modelText != nil:
    if f.getFont != nil and f.setFont != nil:
      let font = f.getFont(modelText)
      if font != nil: f.setFont(label, font)
    if f.getTextSize != nil and f.setTextSize != nil:
      f.setTextSize(label, f.getTextSize(modelText))
  if f.offDepProps >= 0:
    writePtrAt(btn, f.offDepProps, readPtrAt(model, f.offDepProps))

  f.setContent(btn, label)
  btn

proc onPanelLoaded(self: pointer) {.nimcall.} =
  let f = sectionFeature
  if not f.enabled.load() or f.applied or self == nil: return
  let gridMain = readPtrAt(self, f.offGridMain)
  if gridMain == nil:
    logI("section: no _gridMain at LoadContent exit")
    return

  let stack = findNavStack(gridMain)
  if stack == nil:
    logI("section: nav stack not found")
    return
  f.applied = true

  let entries = f.getVisualChildren(stack)
  let existing = childCount(entries)
  let model = childAt(entries, 0)
  if model == nil:
    logI("section: nav has no entry to copy")
    return

  let add = resolveAdd(entries)
  if add == nil:
    logE("section: nav collection has no Add")
    return

  let entry = buildEntry(model)
  if entry == nil:
    logE("section: could not build the entry")
    return

  add(entries, entry)
  logI("section: added " & SECTION_NAME & " after " & $existing & " existing entry(ies)")

method install*(f: SectionFeature): bool =
  if not f.enabled.load():
    logI("vdextra section off: hook skipped")
    return true

  let cp = getClass(CONTROL_PANEL)
  let ui = getClass(UI_ELEMENT)
  let content = getClass(CONTENT_CONTROL)
  f.buttonClass = getClass(BUTTON)
  f.textClass = getClass(TEXT_BLOCK)
  if cp == nil or ui == nil or content == nil or
     f.buttonClass == nil or f.textClass == nil:
    logE("section: a required class is missing")
    return false

  f.offGridMain = fieldOffset(cp, "_gridMain")
  f.offDepProps = fieldOffset(ui, "<DependencyProperties>k__BackingField")
  if f.offGridMain < 0:
    logE("section: _gridMain not found")
    return false

  f.getVisualChildren = cast[GetObjFn](methodAddr(ui, "get_VisualChildren", 0))
  f.setContent = cast[SetObjFn](methodAddr(content, "set_Content", 1))
  f.setText = cast[SetStrFn](methodAddr(f.textClass, "set_Text", 1))
  f.setTextSize = cast[SetF32Fn](methodAddr(f.textClass, "set_TextSize", 1))
  f.getTextSize = cast[GetF32Fn](methodAddr(f.textClass, "get_TextSize", 0))
  f.setFont = cast[SetObjFn](methodAddr(f.textClass, "set_Font", 1))
  f.getFont = cast[GetObjFn](methodAddr(f.textClass, "get_Font", 0))
  if f.getVisualChildren == nil or f.setContent == nil or f.setText == nil:
    logE("section: a required member is missing")
    return false

  if not installLoadContent(): return false
  onLoadContent(onPanelLoaded)

  logI("registered the " & SECTION_NAME & " nav entry")
  true
