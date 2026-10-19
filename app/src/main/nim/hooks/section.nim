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

  ## VD's tab grids paint an opaque background; a constructed one is fully transparent, so the
  ## previous page shows straight through it however often the panel is redrawn.
  BACKGROUND_COLOR_OFFSET = 196

  ## Xenko visibility: 0 Visible, 1 Hidden, 2 Collapsed. VD keeps every tab's grid parented in
  ## the content cell and simply toggles this, so a new tab is one more sibling to flip.
  VISIBILITY_VISIBLE = 0'i32
  VISIBILITY_HIDDEN = 1'i32

  ## A sanity bound on the tab array before it is walked.
  MAX_TABS = 64

  F_RENDER_WIDTH = 104 ## RenderSize.X, the width VD's layout settled on

  ## How long to keep asking for a full repaint after the page is shown or hidden. One frame
  ## leaves the previous tab's pixels on screen: VD clears its dirty regions over several
  ## frames, and a visibility flip made behind its back is not one of them.
  REDRAW_FRAMES = 15

  ## The cell every tab grid occupies in VD's root layout.
  TAB_ROW = 1
  TAB_COLUMN = 1

  PLACEHOLDER_TEXT = "VDExtra settings will live here."
  PLACEHOLDER_SIZE = 20.0

  TEST_BUTTON_TEXT = "Test button"
  TEST_BUTTON_HEIGHT = 56.0
  TEST_BUTTON_WIDTH = 260.0

  ## Our page grid has no strip definitions, so every child stretches over the whole cell.
  ## Pinning each to the top-left and offsetting by margin is what separates them. Xenko orders
  ## these Left/Top, Center, Right/Bottom, Stretch - VD's own stretched controls read 3, which
  ## is how the value was confirmed rather than guessed.
  ALIGN_TOP_LEFT = 0'i32
  PAGE_INSET = 40.0
  LABEL_TOP = 40.0
  BUTTON_TOP = 110.0

  ## VD's entries measure 81 tall; ours measures to its text at 41, since it carries none of
  ## the padding theirs get from the serialised asset. Setting it explicitly is enough now the
  ## entry is in Panel.Children and therefore part of the measure pass.
  NAV_ENTRY_HEIGHT = 81.0

  ## Nav entries span the 300-wide column; the chromed buttons in the bottom bar are narrower,
  ## which is what tells the two apart when looking for a model to copy a button's look from.
  NAV_ENTRY_WIDTH = 300.0

  ## ...but the panel also holds square icon buttons, whose sprite stretched across a wide
  ## button renders as a thin bar. A text button is wider than it is tall, which separates the
  ## two without naming either.
  MODEL_BUTTON_MIN_WIDTH = 150.0


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
    setHAlign, setVAlign: SetI32Fn
    setWidth: SetF32Fn
    offMargin: int
    testButton: pointer ## the page's own button, pinned
    testWasPressed: bool
    navEntries: pointer ## VD's nav collection, for the active highlight
    activeColor, inactiveColor: uint32
    getVisibility: GetI32Fn
    containerSetObject: SetObj2Fn
    containerGetItem: GetObj2Fn
    gridClass, gridBaseClass: MonoClass
    rowKey, columnKey: MonoObject
    offDepProps, offPanelGrid, offTabPanels: int
    offForceDrawAll: int
    content: pointer    ## our tab's grid, pinned
    showing, wasShowing: bool
    redrawFrames: int
    entry: pointer      ## our nav button, pinned
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

## Pins an element to the page's top-left and offsets it, so siblings that would otherwise
## stretch over the whole cell end up stacked instead.
proc placeInPage(el: pointer, top: float) =
  let f = sectionFeature
  if el == nil: return
  if f.setHAlign != nil: f.setHAlign(el, ALIGN_TOP_LEFT)
  if f.setVAlign != nil: f.setVAlign(el, ALIGN_TOP_LEFT)
  if f.offMargin < 0: return
  let m = cast[ptr UncheckedArray[float32]](cast[uint64](el) + uint64(f.offMargin))
  m[0] = float32(PAGE_INSET)
  m[1] = float32(top)

proc copyBackground(fresh, model: pointer) =
  if fresh == nil or model == nil: return
  let colour = cast[ptr uint32](cast[uint64](model) + uint64(BACKGROUND_COLOR_OFFSET))[]
  cast[ptr uint32](cast[uint64](fresh) + uint64(BACKGROUND_COLOR_OFFSET))[] = colour

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

## Builds a label styled after `modelText`. The font is copied as a field rather than through
## set_Font: that setter is hooked by the text feature, which substitutes fonts for glyph
## coverage and would discard this one. Without a font DefaultTextBlockRenderer.RenderColor
## dereferences null and the game thread aborts.
proc makeLabel(modelText: pointer, caption: string): pointer =
  let f = sectionFeature
  let label = newInstance(f.textClass)
  if label == nil: return nil
  discard pin(label)
  let text = makeMono(caption)
  if text == nil: return nil
  f.setText(label, text)
  if modelText != nil:
    adoptFrom(label, modelText, [f.offRenderer, f.offFont, f.offLayoutCtx])
    if f.getTextSize != nil and f.setTextSize != nil:
      f.setTextSize(label, f.getTextSize(modelText))
    setTextColorAt(label, textColorAt(modelText))
  label

## Builds a button styled after `model`, one of VD's own. layoutingContext is what RenderColor
## reaches through; it is null on a fresh control and only ever assigned during VD's own layout
## pass, so the model's is adopted along with the renderer and sprites.
proc makeButton(model: pointer, caption: string, height: float): pointer =
  let f = sectionFeature
  let btn = newInstance(f.buttonClass)
  if btn == nil: return nil
  discard pin(btn)
  adoptFrom(btn, model, [f.offRenderer, f.offPressed, f.offNotPressed, f.offMouseOver,
                         f.offLayoutCtx])

  let label = makeLabel(firstTextBlock(model, 0), caption)
  if label == nil: return nil

  # ClickMode 0 is what VD's own entries use; a fresh Button defaults to 1 and would react on
  # release rather than press, which get_IsPressed never shows.
  if f.setClickMode != nil: f.setClickMode(btn, 0'i32)
  if f.setHeight != nil: f.setHeight(btn, cfloat(height))
  f.setContent(btn, label)
  btn

## The odd one out: with a single tab active, the colour that is not the majority is the one VD
## paints the selected entry with.
proc activeTextColor(entries: pointer, count: int, inactive: uint32): uint32 =
  for i in 0 ..< count:
    let btn = childAt(entries, i)
    if btn == nil: continue
    let colour = textColorAt(firstTextBlock(btn, 0))
    if colour != 0'u32 and colour != inactive: return colour
  inactive

proc buildEntry(model: pointer): pointer =
  makeButton(model, SECTION_NAME, NAV_ENTRY_HEIGHT)

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
## Reading these statics runs GridBase's class constructor, so it happens here - on the game
## thread, inside a managed call - rather than at install time, where Mono aborts the process
## with a thread-state transition error.
proc resolveCellKeys() =
  let f = sectionFeature
  if f.rowKey != nil or f.gridBaseClass == nil: return
  f.rowKey = staticObject(f.gridBaseClass, "RowPropertyKey")
  f.columnKey = staticObject(f.gridBaseClass, "ColumnPropertyKey")

proc placeInTabCell(grid, model: pointer) =
  let f = sectionFeature
  resolveCellKeys()
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
## VD's nav entries are flat text by design, so a button copied from one has no chrome. The
## bottom bar's buttons carry the pressed and hover sprites that make a button look clickable.
proc findChromedButton(root: pointer, depth: int, best: var pointer): void =
  let f = sectionFeature
  if root == nil or depth > NAV_SEARCH_DEPTH or best != nil: return
  let kids = f.getVisualChildren(root)
  let n = childCount(kids)
  if n <= 0 or n > 512: return
  for i in 0 ..< n:
    let child = childAt(kids, i)
    if child == nil: continue
    let width = readF32At(child, F_RENDER_WIDTH)
    if isButton(child) and readPtrAt(child, f.offNotPressed) != nil and
       width >= MODEL_BUTTON_MIN_WIDTH and width < NAV_ENTRY_WIDTH:
      best = child
      return
    findChromedButton(child, depth + 1, best)

proc buildContent(modelGrid, modelText, modelButton: pointer): pointer =
  let f = sectionFeature
  let grid = newInstance(f.gridClass)
  if grid == nil: return nil
  discard pin(grid)
  adoptFrom(grid, modelGrid, [f.offRenderer, f.offLayoutCtx])
  copyBackground(grid, modelGrid)
  placeInTabCell(grid, modelGrid)

  let label = makeLabel(modelText, PLACEHOLDER_TEXT)
  if label == nil: return nil
  if f.setTextSize != nil: f.setTextSize(label, cfloat(PLACEHOLDER_SIZE))

  placeInPage(label, LABEL_TOP)

  let kids = f.getChildren(grid)
  let add = resolveAdd(kids)
  if add == nil: return nil
  add(kids, label)

  # A real control on our own page: proof the section is not just a label, and the thing whose
  # presses the poll reports.
  let button = makeButton(modelButton, TEST_BUTTON_TEXT, TEST_BUTTON_HEIGHT)
  if button != nil:
    if f.setWidth != nil: f.setWidth(button, cfloat(TEST_BUTTON_WIDTH))
    placeInPage(button, BUTTON_TOP)
    add(kids, button)
    f.testButton = button

  if f.setVisibility != nil: f.setVisibility(grid, VISIBILITY_HIDDEN)
  grid

## VD drives tab changes from a settings event rather than from the button, so the only way to
## learn it has switched away from us is to watch one of its own tabs become visible again.
proc anyVdTabVisible(self: pointer): bool =
  let f = sectionFeature
  let tabs = readPtrAt(self, f.offTabPanels)
  if tabs == nil: return false
  let count = childCount(tabs)
  if count <= 0 or count > MAX_TABS: return false
  for i in 0 ..< count:
    let tab = arrayAt(tabs, i)
    if tab == nil: continue
    let grid = readPtrAt(tab, f.offPanelGrid)
    if grid != nil and f.getVisibility(grid) == VISIBILITY_VISIBLE: return true
  false

## Shows our page and hides VD's, or the reverse. Exactly one tab is visible at a time, which is
## the same invariant VD maintains for its own.
## VD paints the entry for the tab it believes is active and knows nothing about ours, so both
## sides are driven here: exactly one entry stays lit, whoever owns the page.
proc syncNavHighlight() =
  let f = sectionFeature
  if f.navEntries == nil or f.entry == nil or
     f.activeColor == 0'u32 or f.inactiveColor == 0'u32: return
  let count = childCount(f.navEntries)
  if count <= 0 or count > MAX_TABS: return
  for i in 0 ..< count:
    let btn = childAt(f.navEntries, i)
    if btn == nil: continue
    let text = firstTextBlock(btn, 0)
    if text == nil: continue
    if btn == f.entry:
      setTextColorAt(text, if f.showing: f.activeColor else: f.inactiveColor)
    elif f.showing:
      # Ours owns the page, so nothing of VD's should look selected.
      setTextColorAt(text, f.inactiveColor)

proc syncContent(self: pointer) =
  let f = sectionFeature
  if f.content == nil or f.setVisibility == nil or f.getVisibility == nil: return
  if not f.showing:
    f.setVisibility(f.content, VISIBILITY_HIDDEN)
    return

  let tabs = readPtrAt(self, f.offTabPanels)
  if tabs == nil: return
  let count = childCount(tabs)
  if count <= 0 or count > MAX_TABS: return
  for i in 0 ..< count:
    let tab = arrayAt(tabs, i)
    if tab == nil: continue
    let grid = readPtrAt(tab, f.offPanelGrid)
    if grid != nil and f.getVisibility(grid) == VISIBILITY_VISIBLE:
      f.setVisibility(grid, VISIBILITY_HIDDEN)
  f.setVisibility(f.content, VISIBILITY_VISIBLE)

## VD repaints only the regions it believes changed, so a visibility flip made behind its back
## leaves the previous tab's pixels on screen. This is the same flag the settings scroller
## needed, held for several frames because one is not enough to clear the old page.
proc pumpRedraw(self: pointer) =
  let f = sectionFeature
  if f.redrawFrames <= 0 or f.offForceDrawAll < 0: return
  writeBoolAt(self, f.offForceDrawAll, true)
  dec f.redrawFrames

## The press is read from our own button each frame rather than hooked. Detouring OnClick
## reached every button in the panel - it is inherited from ButtonBase - and a bad trampoline
## there took VD's whole navigation down with SIGILL. Polling touches nothing but our entry.
proc pollEntry(self: pointer) {.nimcall.} =
  let f = sectionFeature
  if f.entry == nil or f.getPressed == nil or f.getVisibility == nil: return

  # Checked before our own click is handled: on the frame we are selected, VD's tab is still
  # visible because syncContent has not run yet, and testing first would cancel the selection
  # immediately.
  if f.showing and anyVdTabVisible(self):
    f.showing = false

  let pressed = f.getPressed(f.entry)
  if pressed and not f.wasPressed:
    f.showing = true
    logI("section: " & SECTION_NAME & " selected")
  f.wasPressed = pressed

  # The page's own button, reported only while the page is up so a stray read cannot fire it.
  if f.showing and f.testButton != nil:
    let testPressed = f.getPressed(f.testButton)
    if testPressed and not f.testWasPressed:
      logI("section: " & TEST_BUTTON_TEXT & " clicked")
    f.testWasPressed = testPressed
  else:
    f.testWasPressed = false

  syncContent(self)
  syncNavHighlight()
  if f.showing != f.wasShowing:
    f.wasShowing = f.showing
    f.redrawFrames = REDRAW_FRAMES
  pumpRedraw(self)

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
    f.navEntries = entries
    f.inactiveColor = inactive
    f.activeColor = activeTextColor(entries, childCount(entries), inactive)

    add(entries, entry)
    f.entry = entry

    # The tab's own content: a sibling of VD's tab grids in the same cell, hidden until the
    # entry is chosen. VD keeps all of them parented and just toggles visibility.
    let tabs = readPtrAt(self, f.offTabPanels)
    let firstTab = if tabs == nil: nil else: arrayAt(tabs, 0)
    let modelGrid = if firstTab == nil: nil else: readPtrAt(firstTab, f.offPanelGrid)
    if modelGrid != nil:
      let modelText = firstTextBlock(model, 0)
      var chromed: pointer = nil
      findChromedButton(gridMain, 0, chromed)
      let content = buildContent(modelGrid, modelText,
                                 if chromed != nil: chromed else: model)
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
  f.setWidth = cast[SetF32Fn](methodAddr(ui, "set_Width", 1))
  f.setHAlign = cast[SetI32Fn](methodAddr(ui, "set_HorizontalAlignment", 1))
  f.setVAlign = cast[SetI32Fn](methodAddr(ui, "set_VerticalAlignment", 1))
  f.offMargin = fieldOffset(ui, "MarginInternal")
  f.setVisibility = cast[SetI32Fn](methodAddr(ui, "set_Visibility", 1))
  f.getVisibility = cast[GetI32Fn](methodAddr(ui, "get_Visibility", 0))

  f.gridClass = getClass(GRID)
  f.offDepProps = fieldOffset(ui, "<DependencyProperties>k__BackingField")
  f.offPanelGrid = fieldOffset(getClass(UI_PANEL), "<Grid>k__BackingField")
  f.offTabPanels = fieldOffset(cp, "_tabPanels")
  f.offForceDrawAll = fieldOffset(cp, "_forceDrawAll")

  f.gridBaseClass = getClass(GRID_BASE)
  let container = getClass(PROPERTY_CONTAINER)
  if container != nil:
    f.containerSetObject = cast[SetObj2Fn](methodAddr(container, "SetObject", 2))
    f.containerGetItem = cast[GetObj2Fn](methodAddr(container, "get_Item", 1))
  if f.gridClass == nil or f.gridBaseClass == nil or
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
