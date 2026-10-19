import std/atomics
import ../vdlog, ../mono, hook, loadcontent, panelupdate

## Feasibility spike: add a VDExtra entry to the control panel's left navigation.
##
## The nav is a StackPanel of Buttons, each wrapping a TextBlock, so an entry is just one more
## Button appended to it. The work has to happen inside LoadContent because VD measures this
## layout exactly once - an element added later is never laid out, which is what made the
## injected scroller invisible to VD's bounds and depth assignment.
##
## Styling is copied from an existing nav button rather than invented - its renderer, sprites,
## font and text size. DependencyProperties is deliberately NOT copied: that would hand two
## elements one instance, and the panels key their per-child caches by element.

const
  UI_ELEMENT = "Xenko.UI.UIElement, Xenko.UI"
  PANEL = "Xenko.UI.Panels.Panel, Xenko.UI"
  UI_PANEL = "VirtualDesktop.Mobile.UIPanel, VirtualDesktop.Mobile"
  GRID = "Xenko.UI.Panels.Grid, Xenko.UI"
  GRID_BASE = "Xenko.UI.Panels.GridBase, Xenko.UI"
  PROPERTY_CONTAINER = "Xenko.Core.PropertyContainerClass, Xenko.Core"
  BUTTON = "Xenko.UI.Controls.Button, Xenko.UI"
  BUTTON_BASE = "Xenko.UI.Controls.ButtonBase, Xenko.UI"
  TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"
  CONTENT_CONTROL = "Xenko.UI.Controls.ContentControl, Xenko.UI"

  SECTION_NAME = "VDEXTRA"

  ## The nav is the one container whose children are *all* buttons. Matching on "holds at least
  ## four buttons" instead picked the bottom bar first - a Grid of 6 children, 4 of them buttons
  ## - and appending a child a Grid has no strip data for aborts the game thread inside
  ## Grid.RebuildMeasureCacheData.
  MIN_NAV_ENTRIES = 4
  NAV_SEARCH_DEPTH = 8

  ## VD paints the active entry white and the rest grey. A fresh TextBlock starts near-white,
  ## so ours looked permanently selected until it was given the inactive colour.
  TEXT_COLOR_OFFSET = 608

  ## Xenko visibility: 0 Visible, 1 Hidden, 2 Collapsed. VD keeps every tab's grid parented in
  ## the content cell and simply toggles this, so a new tab is one more sibling to flip.
  VISIBILITY_VISIBLE = 0'i32
  VISIBILITY_HIDDEN = 1'i32

  ## The cell every tab grid occupies in VD's root layout.
  TAB_ROW = 1
  TAB_COLUMN = 1

  PLACEHOLDER_TEXT = "VDExtra settings will live here."
  PLACEHOLDER_SIZE = 20.0

  ## VD's entries measure 81 tall; ours measures to its text at 41, since it carries none of
  ## the padding theirs get from the serialised asset. Setting it explicitly is enough now the
  ## entry is in Panel.Children and therefore part of the measure pass.
  NAV_ENTRY_HEIGHT = 81.0


  ## Builds the entry and reports what is still unset, without attaching it. Inserting a control
  ## that is missing something aborts the game thread, and the stack only ever names the first
  ## thing that was missing - this names them all in one run.
  DRY_RUN = false
  REPORT_FIELDS = 24

type
  GetBoolFn = proc(self: pointer): bool {.cdecl, gcsafe.}
  SetI32Fn = proc(self: pointer, v: int32) {.cdecl, gcsafe.}
  GetI32Fn = proc(self: pointer): int32 {.cdecl, gcsafe.}
  SetObj2Fn = proc(self: pointer, key: pointer, value: pointer) {.cdecl, gcsafe.}
  GetObj2Fn = proc(self: pointer, key: pointer): pointer {.cdecl, gcsafe.}
  GetObjFn = proc(self: pointer): pointer {.cdecl, gcsafe.}
  SetObjFn = proc(self: pointer, v: pointer) {.cdecl, gcsafe.}
  AddFn = proc(self: pointer, item: pointer) {.cdecl, gcsafe.}
  SetStrFn = proc(self: pointer, s: MonoString) {.cdecl, gcsafe.}
  SetF32Fn = proc(self: pointer, v: cfloat) {.cdecl, gcsafe.}
  GetF32Fn = proc(self: pointer): cfloat {.cdecl, gcsafe.}

  SectionFeature* = ref object of Feature
    enabled*: Atomic[bool]
    getPressed: GetBoolFn
    setClickMode: SetI32Fn
    setHeight: SetF32Fn
    setVisibility: SetI32Fn
    getVisibility: GetI32Fn
    containerSetObject: SetObj2Fn
    containerGetItem: GetObj2Fn
    gridClass: MonoClass
    rowKey, columnKey: MonoObject
    offDepProps, offPanelGrid, offTabPanels: int
    content: pointer ## our tab's grid, pinned
    showing: bool
    entry: pointer   ## our nav button, pinned
    wasPressed: bool

    offGridMain, offRenderer, offFont, offLayoutCtx, offParent: int
    offPressed, offNotPressed, offMouseOver: int
    buttonClass, textClass: MonoClass
    getVisualChildren: GetObjFn
    getChildren: GetObjFn
    setContent: SetObjFn
    setText: SetStrFn
    setTextSize: SetF32Fn
    getTextSize: GetF32Fn
    applied: bool

var sectionFeature* = SectionFeature(name: "vdextra section")

sectionFeature.enabled.store(true)

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
## render width still reads zero here. The whole tree is searched and the best match kept rather
## than the first, because the first container holding several buttons is the bottom bar.
proc findNavStack(el: pointer, depth: int, best: var pointer, bestCount: var int) =
  let f = sectionFeature
  if el == nil or depth > NAV_SEARCH_DEPTH: return
  let kids = f.getVisualChildren(el)
  let n = childCount(kids)
  if n <= 0 or n > 512: return

  var buttons = 0
  for i in 0 ..< n:
    if isButton(childAt(kids, i)): inc buttons
  # Every child a button, and enough of them: that is the tab list and nothing else.
  if buttons == n and buttons >= MIN_NAV_ENTRIES and buttons > bestCount:
    best = el
    bestCount = buttons

  for i in 0 ..< n:
    findNavStack(childAt(kids, i), depth + 1, best, bestCount)

## mono_object_new allocates the object but runs none of the wiring VD's deserialiser does.
## The gap that matters is Renderer: it is null on a fresh control, and the game thread aborts
## the moment a draw dereferences it. The sprites are what the button is actually painted with.
proc adoptFrom(fresh, model: pointer, offsets: openArray[int]) =
  for off in offsets:
    if off < 0: continue
    let v = readPtrAt(model, off)
    if v != nil: writePtrAt(fresh, off, v)

proc textColorAt(text: pointer): uint32 =
  if text == nil: 0'u32
  else: cast[ptr uint32](cast[uint64](text) + uint64(TEXT_COLOR_OFFSET))[]

proc setTextColorAt(text: pointer, colour: uint32) =
  if text == nil: return
  cast[ptr uint32](cast[uint64](text) + uint64(TEXT_COLOR_OFFSET))[] = colour

## The inactive colour is whatever most entries share: only one tab is active at a time, so the
## majority is the inactive shade. Reading it beats hard-coding grey, which would be wrong the
## moment VD restyles its panel.
proc inactiveTextColor(entries: pointer, count: int): uint32 =
  var tally: array[8, tuple[colour: uint32, hits: int]]
  var used = 0
  for i in 0 ..< count:
    let btn = childAt(entries, i)
    if btn == nil: continue
    let colour = textColorAt(firstTextBlock(btn, 0))
    if colour == 0'u32: continue
    var seen = false
    for j in 0 ..< used:
      if tally[j].colour == colour:
        inc tally[j].hits
        seen = true
        break
    if not seen and used < tally.len:
      tally[used] = (colour, 1)
      inc used

  var bestHits = 0
  for j in 0 ..< used:
    if tally[j].hits > bestHits:
      bestHits = tally[j].hits
      result = tally[j].colour

proc buildEntry(model: pointer): pointer =
  let f = sectionFeature
  let btn = newInstance(f.buttonClass)
  if btn == nil: return nil
  discard pin(btn)

  let label = newInstance(f.textClass)
  if label == nil: return nil
  discard pin(label)

  # layoutingContext is what RenderColor reaches through; it is null on a fresh control and
  # only ever assigned during VD's own layout pass, so the model's is adopted with the rest.
  adoptFrom(btn, model, [f.offRenderer, f.offPressed, f.offNotPressed, f.offMouseOver,
                         f.offLayoutCtx])

  let name = makeMono(SECTION_NAME)
  if name == nil: return nil
  f.setText(label, name)

  # Match the existing entries so the new one is not styled differently.
  # The font is copied as a field rather than through set_Font: that setter is hooked by the
  # text feature, which substitutes fonts for glyph coverage and would discard this one. Without
  # a font DefaultTextBlockRenderer.RenderColor dereferences null and the game thread aborts.
  let modelText = firstTextBlock(model, 0)
  if modelText != nil:
    adoptFrom(label, modelText, [f.offRenderer, f.offFont, f.offLayoutCtx])
    if f.getTextSize != nil and f.setTextSize != nil:
      f.setTextSize(label, f.getTextSize(modelText))
  # ClickMode 0 is what VD's own entries use; a fresh Button defaults to 1 and would react on
  # release rather than press, which get_IsPressed never shows.
  if f.setClickMode != nil: f.setClickMode(btn, 0'i32)
  if f.setHeight != nil: f.setHeight(btn, cfloat(NAV_ENTRY_HEIGHT))

  f.setContent(btn, label)
  btn

## Lists the reference fields set on `model` but still null on `fresh`, which is exactly the set
## that must be adopted for a constructed control to survive a draw.
proc reportGaps(fresh, model: pointer, label: string) =
  if fresh == nil or model == nil or pClassGetFields == nil: return
  var cls = classOf(model)
  var shown = 0
  for _ in 0 ..< 8:
    if cls == nil or shown >= REPORT_FIELDS: break
    var iter: pointer = nil
    while shown < REPORT_FIELDS:
      let fld = pClassGetFields(cls, addr iter)
      if fld == nil: break
      if not fieldIsInstanceRef(fld): continue
      let off = pFieldGetOffset(fld)
      if readPtrAt(model, off) != nil and readPtrAt(fresh, off) == nil:
        logI("section:   " & label & " null: " & nameOf(fld, pFieldGetName) & " @" & $off)
        inc shown
    cls = pClassGetParent(cls)

## Places the grid in the same cell as VD's own tabs. The row and column live in each
## element's property container under GridBase's static keys; the boxed values are taken from a
## real tab rather than created, which avoids boxing an int from native code.
proc placeInTabCell(grid, model: pointer) =
  let f = sectionFeature
  if f.containerSetObject == nil or f.containerGetItem == nil: return
  let ours = readPtrAt(grid, f.offDepProps)
  let theirs = readPtrAt(model, f.offDepProps)
  if ours == nil or theirs == nil: return
  for key in [f.rowKey, f.columnKey]:
    if key == nil: continue
    let boxed = f.containerGetItem(theirs, key)
    if boxed != nil: f.containerSetObject(ours, key, boxed)

## Builds the tab's content: a grid carrying one placeholder label, styled from a real tab so
## it inherits the renderer and layout context a constructed control never receives.
proc buildContent(modelGrid, modelText: pointer): pointer =
  let f = sectionFeature
  let grid = newInstance(f.gridClass)
  if grid == nil: return nil
  discard pin(grid)
  adoptFrom(grid, modelGrid, [f.offRenderer, f.offLayoutCtx])
  placeInTabCell(grid, modelGrid)

  let label = newInstance(f.textClass)
  if label == nil: return nil
  discard pin(label)
  adoptFrom(label, modelText, [f.offRenderer, f.offFont, f.offLayoutCtx])
  let text = makeMono(PLACEHOLDER_TEXT)
  if text == nil: return nil
  f.setText(label, text)
  if f.setTextSize != nil: f.setTextSize(label, cfloat(PLACEHOLDER_SIZE))
  setTextColorAt(label, textColorAt(modelText))

  let kids = f.getChildren(grid)
  let add = resolveAdd(kids)
  if add == nil: return nil
  add(kids, label)

  if f.setVisibility != nil: f.setVisibility(grid, VISIBILITY_HIDDEN)
  grid

## Shows our tab and hides VD's, or steps aside when VD has switched to one of its own.
proc syncContent(self: pointer) =
  let f = sectionFeature
  if f.content == nil or f.setVisibility == nil or f.getVisibility == nil: return
  let tabs = readPtrAt(self, f.offTabPanels)
  if tabs == nil: return
  let count = childCount(tabs)
  if count <= 0 or count > 64: return

  var vdVisible = false
  for i in 0 ..< count:
    let tab = arrayAt(tabs, i)
    if tab == nil: continue
    let grid = readPtrAt(tab, f.offPanelGrid)
    if grid == nil: continue
    if f.showing:
      # Ours is up, so nothing of VD's should be.
      if f.getVisibility(grid) == VISIBILITY_VISIBLE:
        f.setVisibility(grid, VISIBILITY_HIDDEN)
    elif f.getVisibility(grid) == VISIBILITY_VISIBLE:
      vdVisible = true

  if f.showing and vdVisible: discard
  f.setVisibility(f.content, if f.showing: VISIBILITY_VISIBLE else: VISIBILITY_HIDDEN)

## The press is read from our own button each frame rather than hooked. Detouring OnClick
## reached every button in the panel - it is inherited from ButtonBase - and a bad trampoline
## there took VD's whole navigation down with SIGILL. Polling touches nothing but our entry.
proc pollEntry(self: pointer) {.nimcall.} =
  let f = sectionFeature
  if f.entry == nil or f.getPressed == nil: return
  let pressed = f.getPressed(f.entry)
  if pressed and not f.wasPressed:
    f.showing = true
    logI("section: " & SECTION_NAME & " selected")
  f.wasPressed = pressed

  # VD drives tab changes from a settings event, not from the button, so the only way to learn
  # it has switched away is to watch one of its own tabs become visible again.
  if f.showing and f.content != nil and f.getVisibility != nil:
    let tabs = readPtrAt(self, f.offTabPanels)
    if tabs != nil:
      let count = childCount(tabs)
      for i in 0 ..< min(count, 64):
        let tab = arrayAt(tabs, i)
        if tab == nil: continue
        let grid = readPtrAt(tab, f.offPanelGrid)
        if grid != nil and f.getVisibility(grid) == VISIBILITY_VISIBLE:
          f.showing = false
          break
  syncContent(self)

proc onPanelLoaded(self: pointer) {.nimcall.} =
  let f = sectionFeature
  if not f.enabled.load() or f.applied or self == nil: return
  let gridMain = readPtrAt(self, f.offGridMain)
  if gridMain == nil:
    logI("section: no _gridMain at LoadContent exit")
    return

  var stack: pointer = nil
  var stackCount = 0
  findNavStack(gridMain, 0, stack, stackCount)
  if stack == nil:
    logI("section: nav stack not found")
    return
  f.applied = true

  # Panel.Children, not VisualChildren: MeasureOverride and ArrangeOverride iterate Children,
  # so an element added only to the visual tree draws but is never measured, arranged or
  # hit-tested - which is exactly 0x0 size, wrong position, and no response to clicks.
  let entries = f.getChildren(stack)
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

  let modelText = firstTextBlock(model, 0)
  let entryText = firstTextBlock(entry, 0)
  reportGaps(entry, model, "button")
  if entryText != nil and modelText != nil:
    reportGaps(entryText, modelText, "label")

  when DRY_RUN:
    logI("section: dry run, " & SECTION_NAME & " built but not attached to the " &
         $stackCount & "-entry nav")
  else:
    let inactive = inactiveTextColor(entries, childCount(entries))
    if inactive != 0'u32: setTextColorAt(firstTextBlock(entry, 0), inactive)

    add(entries, entry)
    f.entry = entry

    # The tab's own content: a sibling of VD's tab grids in the same cell, hidden until the
    # entry is chosen. VD keeps all of them parented and just toggles visibility.
    let tabs = readPtrAt(self, f.offTabPanels)
    let firstTab = if tabs == nil: nil else: arrayAt(tabs, 0)
    let modelGrid = if firstTab == nil: nil else: readPtrAt(firstTab, f.offPanelGrid)
    if modelGrid != nil:
      let modelText = firstTextBlock(model, 0)
      let content = buildContent(modelGrid, modelText)
      if content == nil:
        logE("section: could not build the tab content")
      else:
        let rootKids = f.getChildren(readPtrAt(self, f.offGridMain))
        let addRoot = resolveAdd(rootKids)
        if addRoot == nil:
          logE("section: root grid has no Add")
        else:
          addRoot(rootKids, content)
          f.content = content
          logI("section: content panel added beside " & $childCount(tabs) & " VD tab(s)")

    logI("section: added " & SECTION_NAME & " to a " & $stackCount & "-entry nav")

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
  f.offRenderer = fieldOffset(ui, "Renderer")
  f.offFont = fieldOffset(f.textClass, "font")
  f.offLayoutCtx = fieldOffset(ui, "layoutingContext")
  f.offParent = fieldOffset(ui, "<Parent>k__BackingField")
  f.offPressed = fieldOffset(f.buttonClass, "pressedImage")
  f.offNotPressed = fieldOffset(f.buttonClass, "notPressedImage")
  f.offMouseOver = fieldOffset(f.buttonClass, "mouseOverImage")
  if f.offRenderer < 0 or f.offFont < 0:
    logE("section: Renderer/font fields not found; a fresh control would abort on draw")
    return false
  if f.offGridMain < 0:
    logE("section: _gridMain not found")
    return false

  f.getVisualChildren = cast[GetObjFn](methodAddr(ui, "get_VisualChildren", 0))
  f.getChildren = cast[GetObjFn](methodAddr(getClass(PANEL), "get_Children", 0))
  f.setContent = cast[SetObjFn](methodAddr(content, "set_Content", 1))
  f.setText = cast[SetStrFn](methodAddr(f.textClass, "set_Text", 1))
  f.setTextSize = cast[SetF32Fn](methodAddr(f.textClass, "set_TextSize", 1))
  f.getTextSize = cast[GetF32Fn](methodAddr(f.textClass, "get_TextSize", 0))
  if f.getVisualChildren == nil or f.getChildren == nil or
     f.setContent == nil or f.setText == nil:
    logE("section: a required member is missing")
    return false

  let buttonBase = getClass(BUTTON_BASE)
  if buttonBase == nil:
    logE("section: ButtonBase not found, the entry would not be clickable")
    return false
  f.getPressed = cast[GetBoolFn](methodAddr(buttonBase, "get_IsPressed", 0))
  f.setClickMode = cast[SetI32Fn](methodAddr(buttonBase, "set_ClickMode", 1))
  f.setHeight = cast[SetF32Fn](methodAddr(ui, "set_Height", 1))
  f.setVisibility = cast[SetI32Fn](methodAddr(ui, "set_Visibility", 1))
  f.getVisibility = cast[GetI32Fn](methodAddr(ui, "get_Visibility", 0))

  f.gridClass = getClass(GRID)
  f.offDepProps = fieldOffset(ui, "<DependencyProperties>k__BackingField")
  f.offPanelGrid = fieldOffset(getClass(UI_PANEL), "<Grid>k__BackingField")
  f.offTabPanels = fieldOffset(cp, "_tabPanels")

  let gridBase = getClass(GRID_BASE)
  if gridBase != nil:
    f.rowKey = staticObject(gridBase, "RowPropertyKey")
    f.columnKey = staticObject(gridBase, "ColumnPropertyKey")
  let container = getClass(PROPERTY_CONTAINER)
  if container != nil:
    f.containerSetObject = cast[SetObj2Fn](methodAddr(container, "SetObject", 2))
    f.containerGetItem = cast[GetObj2Fn](methodAddr(container, "get_Item", 1))
  if f.gridClass == nil or f.rowKey == nil or f.columnKey == nil or
     f.containerSetObject == nil or f.offTabPanels < 0:
    logE("section: tab content members missing; the entry will have no page")
  if f.getPressed == nil:
    logE("section: ButtonBase::get_IsPressed not resolvable")
    return false

  if not installLoadContent(): return false
  onLoadContent(onPanelLoaded)
  if not installPanelUpdate(): return false
  onPanelTick(pollEntry)

  logI("registered the " & SECTION_NAME & " nav entry")
  true
