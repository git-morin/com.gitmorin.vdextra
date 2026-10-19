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

  ## The panel ships seven tabs; a container holding at least this many buttons is the nav
  ## rather than some other row of controls.
  MIN_NAV_ENTRIES = 4
  NAV_SEARCH_DEPTH = 6

type
  GetObjFn = proc(self: pointer): pointer {.cdecl, gcsafe.}
  SetObjFn = proc(self: pointer, v: pointer) {.cdecl, gcsafe.}
  AddFn = proc(self: pointer, item: pointer) {.cdecl, gcsafe.}
  SetStrFn = proc(self: pointer, s: MonoString) {.cdecl, gcsafe.}
  SetF32Fn = proc(self: pointer, v: cfloat) {.cdecl, gcsafe.}
  GetF32Fn = proc(self: pointer): cfloat {.cdecl, gcsafe.}

  SectionFeature* = ref object of Feature
    enabled*: Atomic[bool]

    offGridMain, offDepProps, offRenderer: int
    offPressed, offNotPressed, offMouseOver: int
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

proc childCount(coll: pointer): int =
  if coll == nil: 0
  else: int(cast[ptr int32](cast[uint64](coll) + uint64(LIST_SIZE))[])

proc childAt(coll: pointer, i: int): pointer =
  let items = cast[ptr pointer](cast[uint64](coll) + uint64(LIST_ITEMS))[]
  if items == nil: return nil
  cast[ptr pointer](cast[uint64](items) + uint64(ARRAY_DATA + i * 8))[]

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

proc isButton(o: pointer): bool =
  let target = sectionFeature.buttonClass
  if o == nil or target == nil: return false
  var k = classOf(o)
  for _ in 0 ..< 6:
    if k == nil: break
    if k == target: return true
    k = pClassGetParent(k)
  false

## Identified by structure, not by size: nothing has been measured yet at LoadContent, so every
## render width here still reads zero. The nav is simply the container holding a button per tab.
proc findNavStack(el: pointer, depth: int): pointer =
  let f = sectionFeature
  if el == nil or depth > NAV_SEARCH_DEPTH: return nil
  let kids = f.getVisualChildren(el)
  let n = childCount(kids)
  if n <= 0 or n > 512: return nil

  var buttons = 0
  for i in 0 ..< n:
    if isButton(childAt(kids, i)): inc buttons
  if buttons >= MIN_NAV_ENTRIES: return el

  for i in 0 ..< n:
    let hit = findNavStack(childAt(kids, i), depth + 1)
    if hit != nil: return hit
  nil

## mono_object_new allocates the object but runs none of the wiring VD's deserialiser does.
## The gap that matters is Renderer: it is null on a fresh control, and the game thread aborts
## the moment a draw dereferences it. The sprites are what the button is actually painted with.
proc adoptFrom(fresh, model: pointer, offsets: openArray[int]) =
  for off in offsets:
    if off < 0: continue
    let v = readPtrAt(model, off)
    if v != nil: writePtrAt(fresh, off, v)

proc buildEntry(model: pointer): pointer =
  let f = sectionFeature
  let btn = newInstance(f.buttonClass)
  if btn == nil: return nil
  discard pin(btn)

  let label = newInstance(f.textClass)
  if label == nil: return nil
  discard pin(label)

  adoptFrom(btn, model, [f.offRenderer, f.offPressed, f.offNotPressed, f.offMouseOver])

  let name = makeMono(SECTION_NAME)
  if name == nil: return nil
  f.setText(label, name)

  # Match the existing entries so the new one is not styled differently.
  let modelText = firstTextBlock(model, 0)
  if modelText != nil:
    adoptFrom(label, modelText, [f.offRenderer])
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

  let stack = findNavStack(gridMain, 0)
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
  f.offRenderer = fieldOffset(ui, "Renderer")
  f.offPressed = fieldOffset(f.buttonClass, "pressedImage")
  f.offNotPressed = fieldOffset(f.buttonClass, "notPressedImage")
  f.offMouseOver = fieldOffset(f.buttonClass, "mouseOverImage")
  if f.offRenderer < 0:
    logE("section: UIElement.Renderer not found, a fresh control would abort on draw")
    return false
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
