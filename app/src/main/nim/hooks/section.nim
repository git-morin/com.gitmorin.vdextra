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
  GRID_BASE = "Xenko.UI.Panels.GridBase, Xenko.UI"
  PROPERTY_CONTAINER = "Xenko.Core.PropertyContainerClass, Xenko.Core"
  BUTTON = "Xenko.UI.Controls.Button, Xenko.UI"
  BUTTON_BASE = "Xenko.UI.Controls.ButtonBase, Xenko.UI"
  TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"
  CHECK_BOX = "Xenko.UI.Controls.CheckBox, Xenko.UI"
  SLIDER = "Xenko.UI.Controls.Slider, Xenko.UI"
  UI_CLONER = "Xenko.Engine.Design.UICloner, Xenko.UI"

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
  VISIBILITY_COLLAPSED = 2'i32

  ## A sanity bound on the tab array before it is walked.
  MAX_TABS = 64

  ## How long to keep asking for a full repaint after the page is shown or hidden. One frame
  ## leaves the previous tab's pixels on screen: VD clears its dirty regions over several
  ## frames, and a visibility flip made behind its back is not one of them.
  REDRAW_FRAMES = 15

  ## The cell every tab grid occupies in VD's root layout.
  TAB_ROW = 1
  TAB_COLUMN = 1

  ## VD builds none of its settings rows in code - SettingsTab makes 61 FindVisualChildOfType
  ## calls and not one `new` - so there is no row builder to call into. Every control is
  ## deserialised from a UI asset, and the way VD itself creates one at runtime is to clone a
  ## template: `library.InstantiateElement<Grid>("itemComputer")`, which is UICloner.Clone.
  ## So our rows are clones of VD's, found by what they contain rather than by name so that a
  ## renamed element cannot silently turn into a missing row.
  SETTINGS_TAB = "VirtualDesktop.Mobile.SettingsTab, VirtualDesktop.Mobile"
  ROW_SEARCH_DEPTH = 6
  MAX_ROW_LABELS = 4
  MAX_PAGE_BUTTONS = 8

  ## A settings column is the list itself; the page's overlay grids hold a single sized child.
  MIN_COLUMN_ROWS = 2

  ## Which rows go in the left column; the rest go in the right, as VD's own page is split.
  COLUMN_SPLIT = 6


type
  GetBoolFn = proc(self: pointer): bool {.cdecl, gcsafe.}
  SetI32Fn = proc(self: pointer, v: int32) {.cdecl, gcsafe.}
  GetI32Fn = proc(self: pointer): int32 {.cdecl, gcsafe.}
  SetObj2Fn = proc(self: pointer, key: pointer, value: pointer) {.cdecl, gcsafe.}
  GetObj2Fn = proc(self: pointer, key: pointer): pointer {.cdecl, gcsafe.}
  GetObjFn = proc(self: pointer): pointer {.cdecl, gcsafe.}
  AddFn = proc(self: pointer, item: pointer) {.cdecl, gcsafe.}
  VoidFn = proc(self: pointer) {.cdecl, gcsafe.}
  SetStrFn = proc(self: pointer, s: MonoString) {.cdecl, gcsafe.}

  ## What a row is made of, which decides both the template cloned for it and where its second
  ## label belongs: a toggle's is the description beside it, an action's is the button caption.
  RowKind = enum
    rkToggle, rkChoice, rkSlider

  PageRow = tuple[kind: RowKind, title, detail: string]

  SectionFeature* = ref object of Feature
    enabled*: Atomic[bool]
    getPressed: GetBoolFn
    setClickMode: SetI32Fn
    setVisibility: SetI32Fn

    ## Our page's own buttons, pinned, with the press already seen on each so holding one is
    ## reported once rather than every frame.
    pageButtons: array[MAX_PAGE_BUTTONS, pointer]
    pageButtonNames: array[MAX_PAGE_BUTTONS, string]
    pageButtonHeld: array[MAX_PAGE_BUTTONS, bool]
    pageButtonCount: int

    ## VD's own rows, cloned once per row we draw.
    toggleModel, choiceModel, sliderModel: pointer
    navEntries: pointer ## VD's nav collection, for the active highlight
    activeColor, inactiveColor: uint32
    getVisibility: GetI32Fn
    containerSetObject: SetObj2Fn
    containerGetItem: GetObj2Fn
    gridBaseClass: MonoClass
    rowKey, columnKey: MonoObject
    offDepProps, offPanelGrid, offTabPanels: int
    offForceDrawAll: int
    content: pointer ## our tab's grid, pinned
    showing, wasShowing: bool
    redrawFrames: int
    entry: pointer ## our nav button, pinned
    wasPressed: bool

    offGridMain: int
    buttonClass, textClass: MonoClass
    checkBoxClass, sliderClass: MonoClass
    settingsTabClass: MonoClass
    getVisualChildren: GetObjFn
    getChildren: GetObjFn
    setText: SetStrFn
    cloneMethod: MonoMethod ## UICloner.Clone - static, one UIElement in, a deep copy out
    applied: bool

var sectionFeature* = SectionFeature(name: "vdextra section")

sectionFeature.enabled.store(true)

## The module's options, in the order the page lays them out. Display only for now: the
## captions come from the companion app's own option list and nothing is wired to a setting
## yet, which is why no row reads or writes anything.
const PAGE_ROWS: array[11, PageRow] = [
  (rkToggle, "Fit long settings pages",
   "Tighten row spacing so a translated page stops hiding its last rows"),
  (rkSlider, "Background music volume", ""),
  (rkChoice, "Background music", "Select"),
  (rkToggle, "Disable performance cue sounds",
   "Mute the cues played when streaming quality changes"),
  (rkToggle, "Extend bitrate range",
   "Raise the bitrate ceiling above the stock limit"),
  (rkToggle, "Remove auto speed-test bitrate cap",
   "Skip the bandwidth cap applied after the speed test"),
  (rkToggle, "Force LAN discovery",
   "Still show local PCs even when the server is unreachable"),
  (rkChoice, "UI language", "Select"),
  (rkChoice, "Update channel", "Select"),
  (rkChoice, "Check for updates", "Check"),
  (rkChoice, "Version and credits", "Show")
]

## Collection members live on the instance's own generic type, so they are resolved by walking
## up from the instance rather than from a class name known ahead of time.
proc resolveMethod(coll: pointer, name: string, np: int): pointer =
  var k = classOf(coll)
  for _ in 0 ..< 6:
    if k == nil: break
    let a = methodAddr(k, name, np)
    if a != nil: return a
    k = pClassGetParent(k)
  nil

proc resolveAdd(coll: pointer): AddFn =
  cast[AddFn](resolveMethod(coll, "Add", 1))

## Matched on the exact class, not on inheritance: CheckBox and Button are siblings under
## ButtonBase rather than parent and child, so exactness is what separates a toggle row from an
## action row. LimitSlider derives from Slider for the same reason - only `sldBrightness` is a
## plain Slider, and that is the row we want as the model.
proc firstOfClass(el: pointer, cls: MonoClass, depth: int): pointer =
  let f = sectionFeature
  if el == nil or cls == nil or depth > ROW_SEARCH_DEPTH: return nil
  if classOf(el) == cls: return el
  let kids = f.getVisualChildren(el)
  let n = childCount(kids)
  if n <= 0 or n > 512: return nil
  for i in 0 ..< n:
    let hit = firstOfClass(childAt(kids, i), cls, depth + 1)
    if hit != nil: return hit
  nil

proc firstTextBlock(el: pointer, depth: int): pointer =
  firstOfClass(el, sectionFeature.textClass, depth)

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

## Hands back a deep copy of one of VD's own controls.
##
## This replaces constructing a control and copying fields off a sibling. The copy keeps every
## authored property - sprites, font, text size, margins, chrome - and shares content
## references rather than duplicating them, which is why a cloned button looks like a VD button
## where a constructed one looked like bare text. It deliberately does not carry VD's event
## handlers: delegates are not serialised, so our rows cannot drive VD's settings.
##
## Nothing has to be adopted afterwards. RendererManager assigns a Renderer per element during
## the render walk, and LayoutingContext propagates from the parent the moment the clone is
## added to Panel.Children - the two fields a constructed control had to borrow.
## Invoked through mono_runtime_invoke rather than as a compiled thunk so that a throw comes
## back as an exception object instead of unwinding into native frames and aborting the game.
## Clone serialises an arbitrary object graph, so it is the one call here that can fail on
## something VD authored rather than on a mistake of ours.
proc cloneOf(model: pointer): pointer =
  let f = sectionFeature
  if model == nil or f.cloneMethod == nil or pRuntimeInvoke == nil: return nil
  var args: array[1, pointer]
  args[0] = model
  var exc: MonoObject = nil
  result = pRuntimeInvoke(f.cloneMethod, nil,
                          cast[ptr UncheckedArray[pointer]](addr args[0]), addr exc)
  if exc != nil:
    logE("section: clone of a " & objClassName(model) & " threw " & objClassName(exc))
    return nil
  if result != nil: discard pin(result)

proc setLabel(label: pointer, caption: string) =
  let f = sectionFeature
  if label == nil or f.setText == nil: return
  let s = makeMono(caption)
  if s != nil: f.setText(label, s)

proc collectLabels(el: pointer, depth: int,
                   found: var array[MAX_ROW_LABELS, pointer], n: var int) =
  let f = sectionFeature
  if el == nil or depth > ROW_SEARCH_DEPTH or n >= MAX_ROW_LABELS: return
  if classOf(el) == f.textClass:
    found[n] = el
    inc n
    return
  let kids = f.getVisualChildren(el)
  let c = childCount(kids)
  if c <= 0 or c > 512: return
  for i in 0 ..< c:
    collectLabels(childAt(kids, i), depth + 1, found, n)

## Labels come out in tree order, which is the order the asset was authored in: the option's
## name first, then whatever sits beside it. On a toggle row that is the description; on an
## action row the last label is the button's own caption. A slider row's second label is its
## value readout, so it is left for the wiring to fill in.
proc retextRow(row: pointer, kind: RowKind, title, detail: string) =
  var labels: array[MAX_ROW_LABELS, pointer]
  var n = 0
  collectLabels(row, 0, labels, n)
  if n == 0: return
  setLabel(labels[0], title)
  if detail.len == 0 or n < 2: return
  case kind
  of rkToggle: setLabel(labels[1], detail)
  of rkChoice: setLabel(labels[n - 1], detail)
  of rkSlider: discard

## Keeps our own buttons so their presses can be polled. A clone carries no Click handler, and
## that is the only way back to it.
proc rememberButton(row: pointer, caption: string) =
  let f = sectionFeature
  if f.pageButtonCount >= MAX_PAGE_BUTTONS: return
  let btn = firstOfClass(row, f.buttonClass, 0)
  if btn == nil: return
  f.pageButtons[f.pageButtonCount] = btn
  f.pageButtonNames[f.pageButtonCount] = caption
  inc f.pageButtonCount

proc buildRow(kind: RowKind, title, detail: string): pointer =
  let f = sectionFeature
  let model = case kind
    of rkToggle: f.toggleModel
    of rkChoice: f.choiceModel
    of rkSlider: f.sliderModel
  if model == nil: return nil
  result = cloneOf(model)
  if result == nil: return nil
  # The clone inherits the model's state - a ticked checkbox, a slider part-way along. Nothing
  # reads a setting yet, so what it shows is VD's value and not ours.
  if f.setVisibility != nil: f.setVisibility(result, VISIBILITY_VISIBLE)
  retextRow(result, kind, title, detail)
  if kind == rkChoice: rememberButton(result, title)

## The entry is a clone of one of VD's own rather than a button built to look like one, so it
## arrives with their padding, height, text size and sprites instead of an approximation of
## them - which is what left ours slightly out of line and the wrong shade.
proc buildEntry(model: pointer): pointer =
  let f = sectionFeature
  result = cloneOf(model)
  if result == nil: return nil
  setLabel(firstTextBlock(result, 0), SECTION_NAME)
  # ClickMode 0 is what VD's own entries use; on Release the press is over before a poll sees
  # it, so get_IsPressed never reports one.
  if f.setClickMode != nil: f.setClickMode(result, 0'i32)

## The odd one out: with a single tab active, the colour that is not the majority is the one VD
## paints the selected entry with.
proc activeTextColor(entries: pointer, count: int, inactive: uint32): uint32 =
  for i in 0 ..< count:
    let btn = childAt(entries, i)
    if btn == nil: continue
    let colour = textColorAt(firstTextBlock(btn, 0))
    if colour != 0'u32 and colour != inactive: return colour
  inactive

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

## The settings page's own grid, found by its tab class rather than by index so a reordered
## _tabPanels cannot quietly hand back the wrong page.
proc settingsGrid(self: pointer): pointer =
  let f = sectionFeature
  let tabs = readPtrAt(self, f.offTabPanels)
  if tabs == nil: return nil
  let count = childCount(tabs)
  if count <= 0 or count > MAX_TABS: return nil
  for i in 0 ..< count:
    let tab = arrayAt(tabs, i)
    if tab == nil: continue
    if classOf(tab) == f.settingsTabClass:
      return readPtrAt(tab, f.offPanelGrid)
  nil

## A column holds the rows; the page's other children are overlays - the USB prompt, the colour
## picker, the transparency panel - each a single sized child shown on demand.
proc isColumn(el: pointer): bool =
  let f = sectionFeature
  if el == nil: return false
  childCount(f.getChildren(el)) >= MIN_COLUMN_ROWS

## The first row on the settings page holding a `cls` control. A row is the unit VD's asset
## styles, so cloning one brings its label, its description and its spacing along together -
## which is what makes our page match theirs without a single measurement being copied.
## Collapsed rows are skipped: SettingsTab hides the ones this headset does not support, and a
## hidden template clones into a row that draws nothing.
proc findRowTemplate(grid: pointer, cls: MonoClass): pointer =
  let f = sectionFeature
  if grid == nil or cls == nil: return nil
  let cols = f.getChildren(grid)
  let n = childCount(cols)
  if n <= 0 or n > 512: return nil
  for i in 0 ..< n:
    let col = childAt(cols, i)
    if not isColumn(col): continue
    let rows = f.getChildren(col)
    for j in 0 ..< childCount(rows):
      let row = childAt(rows, j)
      if row == nil or f.getVisibility(row) != VISIBILITY_VISIBLE: continue
      if firstOfClass(row, cls, 0) != nil: return row
  nil

## Fills one emptied column with the rows assigned to it.
proc fillColumn(col: pointer, first, last: int): int =
  let f = sectionFeature
  let kids = f.getChildren(col)
  let clear = resolveMethod(kids, "Clear", 0)
  let add = resolveAdd(kids)
  if clear == nil or add == nil: return 0
  cast[VoidFn](clear)(kids)
  for i in first .. min(last, PAGE_ROWS.high):
    let row = buildRow(PAGE_ROWS[i].kind, PAGE_ROWS[i].title, PAGE_ROWS[i].detail)
    if row == nil: continue
    add(kids, row)
    inc result

## Builds the tab's content as a clone of VD's own settings page with our rows in place of
## theirs.
##
## Hand-building this was the mistake: a Grid from mono_object_new has no row or column
## definitions, so every child it holds is measured against a degenerate slot, and the columns
## came out overlapping whatever width and margins they were given. Cloning the page instead
## inherits the strip definitions, the background, the cell placement and the two columns'
## exact geometry, which leaves nothing about the layout for us to get wrong.
proc buildContent(settings: pointer): pointer =
  let f = sectionFeature
  f.toggleModel = findRowTemplate(settings, f.checkBoxClass)
  f.choiceModel = findRowTemplate(settings, f.buttonClass)
  f.sliderModel = findRowTemplate(settings, f.sliderClass)
  logI("section: row models toggle=" & $(f.toggleModel != nil) &
       " choice=" & $(f.choiceModel != nil) &
       " slider=" & $(f.sliderModel != nil))

  let page = cloneOf(settings)
  if page == nil: return nil
  placeInTabCell(page, settings)

  let kids = f.getChildren(page)
  let n = childCount(kids)
  if n <= 0 or n > 512: return nil

  var filled, columns = 0
  for i in 0 ..< n:
    let child = childAt(kids, i)
    if child == nil: continue
    if not isColumn(child):
      # An overlay of VD's, with no meaning on our page and nothing to show it.
      if f.setVisibility != nil: f.setVisibility(child, VISIBILITY_COLLAPSED)
      continue
    filled += (if columns == 0: fillColumn(child, 0, COLUMN_SPLIT - 1)
      else: fillColumn(child, COLUMN_SPLIT, PAGE_ROWS.high))
    inc columns
    if columns >= 2: break

  logI("section: page has " & $columns & " column(s), " & $filled & " row(s), " &
       $f.pageButtonCount & " button(s)")
  if filled == 0: return nil

  if f.setVisibility != nil: f.setVisibility(page, VISIBILITY_HIDDEN)
  page

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

  # The page's own buttons, read only while the page is up so a press somewhere else cannot be
  # attributed to one of ours.
  for i in 0 ..< f.pageButtonCount:
    let btn = f.pageButtons[i]
    if btn == nil: continue
    let held = f.showing and f.getPressed(btn)
    if held and not f.pageButtonHeld[i]:
      logI("section: " & f.pageButtonNames[i] & " clicked")
    f.pageButtonHeld[i] = held

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

  let inactive = inactiveTextColor(entries, childCount(entries))
  if inactive != 0'u32: setTextColorAt(firstTextBlock(entry, 0), inactive)
  f.navEntries = entries
  f.inactiveColor = inactive
  f.activeColor = activeTextColor(entries, childCount(entries), inactive)

  add(entries, entry)
  f.entry = entry

  # The tab's own content: a sibling of VD's tab grids in the same cell, hidden until the entry
  # is chosen. VD keeps all of them parented and just toggles visibility.
  let settings = settingsGrid(self)
  if settings == nil:
    logE("section: settings page not found, there is nothing to clone")
  else:
    let content = buildContent(settings)
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
        logI("section: content panel added beside " &
             $childCount(readPtrAt(self, f.offTabPanels)) & " VD tab(s)")

  logI("section: added " & SECTION_NAME & " to a " & $stackCount & "-entry nav")

method install*(f: SectionFeature): bool =
  if not f.enabled.load():
    logI("vdextra section off: hook skipped")
    return true

  let cp = getClass(CONTROL_PANEL)
  let ui = getClass(UI_ELEMENT)
  f.buttonClass = getClass(BUTTON)
  f.textClass = getClass(TEXT_BLOCK)
  f.checkBoxClass = getClass(CHECK_BOX)
  f.sliderClass = getClass(SLIDER)
  f.settingsTabClass = getClass(SETTINGS_TAB)
  if cp == nil or ui == nil or f.buttonClass == nil or f.textClass == nil:
    logE("section: a required class is missing")
    return false
  if f.checkBoxClass == nil or f.sliderClass == nil or f.settingsTabClass == nil:
    logE("section: a row model class is missing; the page will have no rows")

  let cloner = getClass(UI_CLONER)
  if cloner != nil and pClassGetMethod != nil:
    f.cloneMethod = pClassGetMethod(cloner, "Clone", 1)
  if f.cloneMethod == nil:
    logE("section: UICloner::Clone not resolvable, nothing can be cloned")
    return false

  f.offGridMain = fieldOffset(cp, "_gridMain")
  if f.offGridMain < 0:
    logE("section: _gridMain not found")
    return false

  f.getVisualChildren = cast[GetObjFn](methodAddr(ui, "get_VisualChildren", 0))
  f.getChildren = cast[GetObjFn](methodAddr(getClass(PANEL), "get_Children", 0))
  f.setText = cast[SetStrFn](methodAddr(f.textClass, "set_Text", 1))
  if f.getVisualChildren == nil or f.getChildren == nil or f.setText == nil:
    logE("section: a required member is missing")
    return false

  let buttonBase = getClass(BUTTON_BASE)
  if buttonBase == nil:
    logE("section: ButtonBase not found, the entry would not be clickable")
    return false
  f.getPressed = cast[GetBoolFn](methodAddr(buttonBase, "get_IsPressed", 0))
  f.setClickMode = cast[SetI32Fn](methodAddr(buttonBase, "set_ClickMode", 1))
  f.setVisibility = cast[SetI32Fn](methodAddr(ui, "set_Visibility", 1))
  f.getVisibility = cast[GetI32Fn](methodAddr(ui, "get_Visibility", 0))

  f.offDepProps = fieldOffset(ui, "<DependencyProperties>k__BackingField")
  f.offPanelGrid = fieldOffset(getClass(UI_PANEL), "<Grid>k__BackingField")
  f.offTabPanels = fieldOffset(cp, "_tabPanels")
  f.offForceDrawAll = fieldOffset(cp, "_forceDrawAll")

  f.gridBaseClass = getClass(GRID_BASE)
  let container = getClass(PROPERTY_CONTAINER)
  if container != nil:
    f.containerSetObject = cast[SetObj2Fn](methodAddr(container, "SetObject", 2))
    f.containerGetItem = cast[GetObj2Fn](methodAddr(container, "get_Item", 1))
  if f.gridBaseClass == nil or f.containerSetObject == nil or f.offTabPanels < 0:
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
