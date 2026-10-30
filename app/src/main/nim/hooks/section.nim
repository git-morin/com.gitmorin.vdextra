include nemohooks/features

import std/atomics
import nemohooks
import nemohooks/backends/mono
import ../xenko, ../settings, ../fontmap, loadcontent, panelupdate

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
  GAME_SYSTEM = "VirtualDesktop.Mobile.GameSystem, VirtualDesktop.Mobile"
  VD_GAME = "VirtualDesktop.Mobile.Game, VirtualDesktop.Mobile"
  SOUND_SYSTEM = "VirtualDesktop.Mobile.SoundSystem, VirtualDesktop.Mobile"
  SLIDER = "Xenko.UI.Controls.Slider, Xenko.UI"
  UI_CLONER = "Xenko.Engine.Design.UICloner, Xenko.UI"

  SECTION_NAME = "VDEXTRA"
  MIN_NAV_ENTRIES = 4
  NAV_SEARCH_DEPTH = 8
  TEXT_COLOR_OFFSET = 608
  BACKGROUND_COLOR_OFFSET = 196
  VISIBILITY_VISIBLE = 0'i32
  VISIBILITY_HIDDEN = 1'i32
  VISIBILITY_COLLAPSED = 2'i32
  MOUSE_OVER_NONE = 0'i32
  MAX_TABS = 64
  REDRAW_FRAMES = 15
  TAB_ROW = 1
  TAB_COLUMN = 1
  SETTINGS_TAB = "VirtualDesktop.Mobile.SettingsTab, VirtualDesktop.Mobile"
  ROW_SEARCH_DEPTH = 6
  MAX_ROW_LABELS = 4
  MAX_PAGE_BUTTONS = 8
  MIN_COLUMN_ROWS = 2
  NOTE_INDENT = 40.0
  ROW_GAP = 16.0'f32
  COLUMN_TOP = 48.0'f32
  BUTTON_TEXT_COLOR = 0xFFA0A0A0'u32
  TOGGLE_CHECKED = 0'i32
  TOGGLE_UNCHECKED = 2'i32
  VALUE_EPSILON = 0.001'f32
  MAX_BOUND_ROWS = 24
  TEXT_ALIGN_RIGHT = 2'i32
  ALIGN_RIGHT = 2'i32
  ALIGN_BOTTOM = 0'i32
  CREDIT_MARGIN = 16.0'f32
  HEART = "\u2665"
  HEART_FALLBACK = "<3"
  CREDIT_BY = " by git-morin"


type
  GetBoolFn = proc(self: pointer): bool {.cdecl, gcsafe.}
  SetI32Fn = proc(self: pointer, v: int32) {.cdecl, gcsafe.}
  GetI32Fn = proc(self: pointer): int32 {.cdecl, gcsafe.}
  SetObj2Fn = proc(self: pointer, key: pointer, value: pointer) {.cdecl, gcsafe.}
  GetObj2Fn = proc(self: pointer, key: pointer): pointer {.cdecl, gcsafe.}
  GetObjFn = proc(self: pointer): pointer {.cdecl, gcsafe.}
  SetBoolFn = proc(self: pointer, v: bool) {.cdecl, gcsafe.}
  AddFn = proc(self: pointer, item: pointer) {.cdecl, gcsafe.}
  VoidFn = proc(self: pointer) {.cdecl, gcsafe.}
  SetStrFn = proc(self: pointer, s: MonoString) {.cdecl, gcsafe.}
  GetF32Fn = proc(self: pointer): cfloat {.cdecl, gcsafe.}
  SetF32Fn = proc(self: pointer, v: cfloat) {.cdecl, gcsafe.}

  RowKind = enum
    rkHeader, rkToggle, rkNote, rkSlider, rkButton

  PageRow = tuple[column: int, kind: RowKind, setting: Setting, text: string]

  BoundRow = object
    control: pointer
    setting: Setting
    kind: RowKind
    seen: float32
    valueLabel: pointer

  SectionFeature* = ref object of Feature
    enabled*: Atomic[bool]
    getPressed: GetBoolFn
    setClickMode: SetI32Fn
    setVisibility: SetI32Fn
    pageButtons: array[MAX_PAGE_BUTTONS, pointer]
    pageButtonNames: array[MAX_PAGE_BUTTONS, string]
    pageButtonHeld: array[MAX_PAGE_BUTTONS, bool]
    pageButtonCount: int
    bound: array[MAX_BOUND_ROWS, BoundRow]
    boundCount: int
    getToggleState: GetI32Fn
    setToggleState: SetI32Fn
    getSliderValue: GetF32Fn
    setSliderValue: SetF32Fn
    setSliderMin, setSliderMax: SetF32Fn
    headerModel, toggleModel, noteModel, sliderModel, buttonModel: pointer
    setEnabled: SetBoolFn
    offMargin: int
    navEntries: pointer
    activeColor, inactiveColor: uint32
    getVisibility: GetI32Fn
    containerSetObject: SetObj2Fn
    containerGetItem: GetObj2Fn
    gridBaseClass: MonoClass
    rowKey, columnKey: MonoObject
    offDepProps, offPanelGrid, offTabPanels, offCurrentTab: int
    offForceDrawAll: int
    content: pointer
    showing, wasShowing: bool
    redrawFrames: int
    entry: pointer
    wasPressed: bool
    wasOver: bool
    getMouseOver: GetI32Fn
    playClick, playMouseOver: VoidFn
    offGame, offSound: int
    offGridMain: int
    buttonClass, textClass: MonoClass
    getFont: GetObjFn
    setWrap: SetBoolFn
    setTextAlignment: SetI32Fn
    setHorizontalAlignment, setVerticalAlignment: SetI32Fn
    offTextFont: int
    version: string
    checkBoxClass, sliderClass: MonoClass
    settingsTabClass: MonoClass
    getVisualChildren: GetObjFn
    getChildren: GetObjFn
    setText: SetStrFn
    cloneMethod: MonoMethod
    applied: bool

var sectionFeature* = SectionFeature(name: "vdextra section")

sectionFeature.enabled.store(true)

const PAGE_ROWS: array[14, PageRow] = [
  (0, rkSlider, stMusicVolume, "Background music volume"),
  (0, rkToggle, stNoPerfSound, "Disable performance cue sounds"),
  (0, rkNote, stNone, "Mute the cues played when streaming quality changes"),
  (0, rkHeader, stNone, "Network"),
  (0, rkToggle, stForceLan, "Force LAN discovery"),
  (0, rkNote, stNone, "Still show local PCs even when the server is unreachable"),

  (1, rkHeader, stNone, "Bitrate"),
  (1, rkToggle, stBitrateExtend, "Extend bitrate range"),
  (1, rkNote, stNone, "Raise the bitrate ceiling above the stock limit"),
  (1, rkSlider, stBitrateScale, "Bitrate ceiling multiplier"),
  (1, rkToggle, stBitrateUnlock, "Remove auto speed-test bitrate cap"),
  (1, rkNote, stNone, "Skip the bandwidth cap applied after the speed test"),
  (1, rkHeader, stNone, "In the VDExtra app"),
  (1, rkNote, stNone, "Page fit, music source, UI language, update channel and cue sounds")
]

proc resolveMethod(coll: pointer, name: string, np: int): pointer =
  var k = classOf(coll)
  for _ in 0 ..< 6:
    if k == nil: break
    let a = methodAddr(k, name, np)
    if a != nil: return a
    k = pClassGetParent(k)
  nil

proc resolveAdd(coll: pointer): AddFn =
  asProc[AddFn](resolveMethod(coll, "Add", 1))

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

proc findNavStack(el: pointer, depth: int, best: var pointer, bestCount: var int) =
  let f = sectionFeature
  if el == nil or depth > NAV_SEARCH_DEPTH: return
  let kids = f.getVisualChildren(el)
  let n = childCount(kids)
  if n <= 0 or n > 512: return

  var buttons = 0
  for i in 0 ..< n:
    if isButton(childAt(kids, i)): inc buttons
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

proc inactiveTextColor(entries: pointer, count: int): uint32 =
  result = 0'u32
  var tally {.noinit.}: array[8, tuple[colour: uint32, hits: int]]
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

proc cloneOf(model: pointer): pointer =
  let f = sectionFeature
  if model == nil or f.cloneMethod == nil or pRuntimeInvoke == nil: return nil
  var args {.noinit.}: array[1, pointer]
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

proc retextRow(row: pointer, text: string) =
  let f = sectionFeature
  var labels {.noinit.}: array[MAX_ROW_LABELS, pointer]
  var n = 0
  collectLabels(row, 0, labels, n)
  if n > 0: setLabel(labels[0], text)
  if f.setWrap != nil:
    for i in 0 ..< n: f.setWrap(labels[i], true)

proc enableRow(row: pointer) =
  let f = sectionFeature
  if f.setEnabled != nil: f.setEnabled(row, true)
  let btn = firstOfClass(row, f.buttonClass, 0)
  if btn == nil: return
  if f.setEnabled != nil: f.setEnabled(btn, true)
  setTextColorAt(firstTextBlock(btn, 0), BUTTON_TEXT_COLOR)

proc rememberButton(row: pointer, caption: string) =
  let f = sectionFeature
  if f.pageButtonCount >= MAX_PAGE_BUTTONS: return
  let btn = firstOfClass(row, f.buttonClass, 0)
  if btn == nil: return
  f.pageButtons[f.pageButtonCount] = btn
  f.pageButtonNames[f.pageButtonCount] = caption
  inc f.pageButtonCount

proc marginAt(el: pointer, edge: int): float32 =
  let f = sectionFeature
  if el == nil or f.offMargin < 0: return 0'f32
  cast[ptr float32](cast[uint64](el) + uint64(f.offMargin + edge * 4))[]

proc setMarginAt(el: pointer, edge: int, v: float32) =
  let f = sectionFeature
  if el == nil or f.offMargin < 0: return
  cast[ptr float32](cast[uint64](el) + uint64(f.offMargin + edge * 4))[] = v

proc marginLeft(el: pointer): float32 =
  marginAt(el, THICKNESS_LEFT)

proc spaceRow(row: pointer, kind: RowKind) =
  let f = sectionFeature
  if marginAt(row, THICKNESS_BOTTOM) < ROW_GAP:
    setMarginAt(row, THICKNESS_BOTTOM, ROW_GAP)
  if kind == rkButton and f.toggleModel != nil:
    setMarginAt(row, THICKNESS_LEFT, marginLeft(f.toggleModel))

proc rowControl(row: pointer, kind: RowKind): pointer =
  let f = sectionFeature
  case kind
  of rkToggle: firstOfClass(row, f.checkBoxClass, 0)
  of rkSlider: firstOfClass(row, f.sliderClass, 0)
  else: nil

proc controlValue(b: BoundRow): float32 =
  let f = sectionFeature
  case b.kind
  of rkToggle:
    if f.getToggleState == nil: 0'f32
    elif f.getToggleState(b.control) == TOGGLE_CHECKED: 1'f32 else: 0'f32
  of rkSlider:
    if f.getSliderValue == nil: 0'f32 else: float32(f.getSliderValue(b.control))
  else: 0'f32

proc showValue(b: BoundRow, v: float32) =
  let f = sectionFeature
  if b.valueLabel != nil: setLabel(b.valueLabel, format(b.setting, v))
  case b.kind
  of rkToggle:
    if f.setToggleState != nil:
      f.setToggleState(b.control, if v >= 0.5'f32: TOGGLE_CHECKED else: TOGGLE_UNCHECKED)
  of rkSlider:
    let (lo, hi) = bounds(b.setting)
    if f.setSliderMin != nil: f.setSliderMin(b.control, cfloat(lo))
    if f.setSliderMax != nil: f.setSliderMax(b.control, cfloat(hi))
    if f.setSliderValue != nil: f.setSliderValue(b.control, cfloat(v))
  else: discard

proc bindRow(row: pointer, kind: RowKind, setting: Setting) =
  let f = sectionFeature
  if setting == stNone or f.boundCount >= MAX_BOUND_ROWS: return
  let control = rowControl(row, kind)
  if control == nil:
    logE("section: " & $setting & " has no control to bind")
    return
  discard pin(control)
  var b = BoundRow(control: control, setting: setting, kind: kind, seen: 0'f32)
  if kind == rkSlider:
    var labels {.noinit.}: array[MAX_ROW_LABELS, pointer]
    var n = 0
    collectLabels(row, 0, labels, n)
    if n >= 2:
      b.valueLabel = labels[1]
      discard pin(b.valueLabel)
    else:
      logE("section: " & $setting & " slider row has no value label")
  let v = readValue(setting)
  let before = if kind == rkToggle and f.getToggleState != nil:
                 f.getToggleState(control) else: -1'i32
  showValue(b, v)
  b.seen = controlValue(b)
  let after = if kind == rkToggle and f.getToggleState != nil:
                f.getToggleState(control) else: -1'i32
  logI("section: bound " & $setting & " want=" & describe(setting, v) &
       " got=" & describe(setting, b.seen) &
       (if kind == rkToggle: " rawState " & $before & "->" & $after else: ""))
  f.bound[f.boundCount] = b
  inc f.boundCount

proc setVersion*(v: string) =
  sectionFeature.version = v

proc fontHas(font: pointer, text: string): bool =
  if font == nil: return false
  var units: seq[uint16] = @[]
  utf8ToUtf16(text, units)
  if units.len == 0: return false
  fontCovers(font, cast[ptr UncheckedArray[uint16]](addr units[0]), units.len)

proc heartFont(): pointer =
  let f = sectionFeature
  if f.getFont == nil or f.noteModel == nil or f.offTextFont < 0: return nil
  let own = f.getFont(f.noteModel)
  if fontHas(own, HEART): return own # nothing to swap, it already has it
  let full = pickReplacement(fontSize(own))
  if full != nil and fontHas(full, HEART): return full
  nil

proc buildCredit(): pointer =
  let f = sectionFeature
  if f.noteModel == nil: return nil
  let font = heartFont()
  let heart = if font != nil: HEART else: HEART_FALLBACK
  logI("section: credit heart=" & (if font != nil: "glyph" else: "ascii"))
  result = cloneOf(f.noteModel)
  if result == nil: return nil
  if f.setVisibility != nil: f.setVisibility(result, VISIBILITY_VISIBLE)

  let made = "Made with " & heart & CREDIT_BY
  setLabel(result, if f.version.len == 0: made else:
                   SECTION_NAME & " " & f.version & "\n" & made)

  if f.setTextAlignment != nil: f.setTextAlignment(result, TEXT_ALIGN_RIGHT)
  if f.setHorizontalAlignment != nil: f.setHorizontalAlignment(result, ALIGN_RIGHT)
  if f.setVerticalAlignment != nil: f.setVerticalAlignment(result, ALIGN_BOTTOM)
  if font != nil and f.offTextFont >= 0: writePtrAt(result, f.offTextFont, font)

  setMarginAt(result, THICKNESS_LEFT, 0'f32)
  setMarginAt(result, THICKNESS_TOP, 0'f32)
  setMarginAt(result, THICKNESS_RIGHT, CREDIT_MARGIN)
  setMarginAt(result, THICKNESS_BOTTOM, CREDIT_MARGIN)

proc buildRow(kind: RowKind, text: string, setting: Setting): pointer =
  let f = sectionFeature
  let model = case kind
    of rkHeader: f.headerModel
    of rkToggle: f.toggleModel
    of rkNote: f.noteModel
    of rkSlider: f.sliderModel
    of rkButton: f.buttonModel
  if model == nil: return nil
  result = cloneOf(model)
  if result == nil: return nil
  if f.setVisibility != nil: f.setVisibility(result, VISIBILITY_VISIBLE)
  enableRow(result)
  spaceRow(result, kind)
  retextRow(result, text)
  if kind == rkButton: rememberButton(result, text)
  bindRow(result, kind, setting)

proc buildEntry(model: pointer): pointer =
  let f = sectionFeature
  result = cloneOf(model)
  if result == nil: return nil
  setLabel(firstTextBlock(result, 0), SECTION_NAME)
  if f.setClickMode != nil: f.setClickMode(result, 0'i32)

proc activeTextColor(entries: pointer, count: int, inactive: uint32): uint32 =
  for i in 0 ..< count:
    let btn = childAt(entries, i)
    if btn == nil: continue
    let colour = textColorAt(firstTextBlock(btn, 0))
    if colour != 0'u32 and colour != inactive: return colour
  inactive

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

proc isColumn(el: pointer): bool =
  let f = sectionFeature
  if el == nil: return false
  childCount(f.getChildren(el)) >= MIN_COLUMN_ROWS

iterator settingsRows(grid: pointer): pointer {.sideEffect.} =
  let f = sectionFeature
  if grid != nil:
    let cols = f.getChildren(grid)
    let n = childCount(cols)
    if n > 0 and n <= 512:
      for i in 0 ..< n:
        let col = childAt(cols, i)
        if isColumn(col):
          let rows = f.getChildren(col)
          for j in 0 ..< childCount(rows):
            let row = childAt(rows, j)
            if row != nil and f.getVisibility(row) == VISIBILITY_VISIBLE:
              yield row

proc findRowTemplate(grid: pointer, cls: MonoClass): pointer =
  if cls == nil: return nil
  for row in settingsRows(grid):
    if firstOfClass(row, cls, 0) != nil: return row
  nil

proc findTextTemplate(grid: pointer, indented: bool): pointer =
  let f = sectionFeature
  for row in settingsRows(grid):
    if classOf(row) == f.textClass and (marginLeft(row) >= NOTE_INDENT) == indented:
      return row
  nil

proc fillColumn(col: pointer, index: int): int =
  result = 0
  let f = sectionFeature
  let kids = f.getChildren(col)
  let clear = resolveMethod(kids, "Clear", 0)
  let add = resolveAdd(kids)
  if clear == nil or add == nil: return 0
  let wasTop = marginAt(col, THICKNESS_TOP)
  setMarginAt(col, THICKNESS_TOP, COLUMN_TOP)
  logI("section: column " & $index & " top margin " & $wasTop & " -> " &
       $marginAt(col, THICKNESS_TOP))
  asProc[VoidFn](clear)(kids)
  var firstRow: pointer = nil
  for spec in PAGE_ROWS:
    if spec.column == index:
      let row = buildRow(spec.kind, spec.text, spec.setting)
      if row != nil:
        add(kids, row)
        if firstRow == nil: firstRow = row
        inc result
  if firstRow != nil: setMarginAt(firstRow, THICKNESS_TOP, COLUMN_TOP)

proc buildContent(settings: pointer): pointer =
  let f = sectionFeature
  f.toggleModel = findRowTemplate(settings, f.checkBoxClass)
  f.buttonModel = findRowTemplate(settings, f.buttonClass)
  f.sliderModel = findRowTemplate(settings, f.sliderClass)
  f.headerModel = findTextTemplate(settings, indented = false)
  f.noteModel = findTextTemplate(settings, indented = true)
  logI("section: models header=" & $(f.headerModel != nil) &
       " toggle=" & $(f.toggleModel != nil) &
       " note=" & $(f.noteModel != nil) &
       " slider=" & $(f.sliderModel != nil) &
       " button=" & $(f.buttonModel != nil))

  let page = cloneOf(settings)
  if page == nil: return nil
  placeInTabCell(page, settings)

  let kids = f.getChildren(page)
  let n = childCount(kids)
  if n <= 0 or n > 512: return nil

  var filled, columns = 0
  var lastColumn: pointer = nil
  for i in 0 ..< n:
    let child = childAt(kids, i)
    if child == nil: continue
    if not isColumn(child):
      if f.setVisibility != nil: f.setVisibility(child, VISIBILITY_COLLAPSED)
      continue
    filled += fillColumn(child, columns)
    lastColumn = child
    inc columns
    if columns >= 2: break

  if lastColumn != nil:
    let credit = buildCredit()
    let addToPage = resolveAdd(kids)
    if credit != nil and addToPage != nil:
      placeInTabCell(credit, lastColumn)
      addToPage(kids, credit)

  logI("section: page has " & $columns & " column(s), " & $filled & " row(s), " &
       $f.pageButtonCount & " button(s)")
  if filled == 0: return nil

  if f.setVisibility != nil: f.setVisibility(page, VISIBILITY_HIDDEN)
  page

proc playCue(self: pointer, cue: VoidFn) =
  let f = sectionFeature
  if cue == nil or f.offGame < 0 or f.offSound < 0: return
  let game = readPtrAt(self, f.offGame)
  if game == nil: return
  let sound = readPtrAt(game, f.offSound)
  if sound != nil: cue(sound)

proc vdEntryPressed(): bool =
  let f = sectionFeature
  if f.navEntries == nil or f.getPressed == nil: return false
  let n = childCount(f.navEntries)
  if n <= 0 or n > MAX_TABS: return false
  for i in 0 ..< n:
    let btn = childAt(f.navEntries, i)
    if btn != nil and btn != f.entry and f.getPressed(btn): return true
  false

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

proc navColor(btn: pointer, selected: bool): uint32 =
  let f = sectionFeature
  if selected: return f.activeColor
  if f.getMouseOver != nil and f.getMouseOver(btn) != MOUSE_OVER_NONE: return f.activeColor
  f.inactiveColor

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
      setTextColorAt(text, navColor(btn, f.showing))
    elif f.showing:
      setTextColorAt(text, navColor(btn, false))

proc standDown(self: pointer) =
  let f = sectionFeature
  if not f.showing: return
  f.showing = false
  if f.offCurrentTab < 0 or f.setVisibility == nil: return
  let tab = readPtrAt(self, f.offCurrentTab)
  if tab == nil: return
  let grid = readPtrAt(tab, f.offPanelGrid)
  if grid != nil: f.setVisibility(grid, VISIBILITY_VISIBLE)

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

proc pumpRedraw(self: pointer) =
  let f = sectionFeature
  if f.redrawFrames <= 0 or f.offForceDrawAll < 0: return
  writeBoolAt(self, f.offForceDrawAll, true)
  dec f.redrawFrames

proc pollEntry(self: pointer) {.nimcall.} =
  let f = sectionFeature
  if f.entry == nil or f.getPressed == nil or f.getVisibility == nil: return
  if f.showing and anyVdTabVisible(self):
    f.showing = false
  elif f.showing and vdEntryPressed():
    standDown(self)

  let over = f.getMouseOver != nil and f.getMouseOver(f.entry) != MOUSE_OVER_NONE
  if over and not f.wasOver: playCue(self, f.playMouseOver)
  f.wasOver = over

  let pressed = f.getPressed(f.entry)
  if pressed and not f.wasPressed:
    f.showing = true
    playCue(self, f.playClick)
    logI("section: " & SECTION_NAME & " selected")
  f.wasPressed = pressed

  if f.showing:
    for i in 0 ..< f.boundCount:
      let b = f.bound[i]
      if b.control == nil: continue
      let v = controlValue(b)
      if abs(v - b.seen) < VALUE_EPSILON: continue
      f.bound[i].seen = v
      if b.valueLabel != nil: setLabel(b.valueLabel, format(b.setting, v))
      writeValue(b.setting, v)
      markDirty()
      f.redrawFrames = REDRAW_FRAMES
      if b.kind == rkSlider: logD("section: " & $b.setting & " = " & describe(b.setting, v))
      else: logI("section: " & $b.setting & " = " & describe(b.setting, v))

  for i in 0 ..< f.pageButtonCount:
    let btn = f.pageButtons[i]
    if btn == nil: continue
    let held = f.showing and f.getPressed(btn)
    if held != f.pageButtonHeld[i]:
      f.redrawFrames = REDRAW_FRAMES
      if held: logI("section: " & f.pageButtonNames[i] & " clicked")
    f.pageButtonHeld[i] = held

  flushIfSettled()

  syncContent(self)
  syncNavHighlight()
  if f.showing != f.wasShowing:
    f.wasShowing = f.showing
    if not f.showing: flush()
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
  let entries = f.getChildren(stack)
  let model = childAt(entries, min(1, childCount(entries) - 1))
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

  f.getVisualChildren = asProc[GetObjFn](methodAddr(ui, "get_VisualChildren", 0))
  f.getChildren = asProc[GetObjFn](methodAddr(getClass(PANEL), "get_Children", 0))
  f.setText = asProc[SetStrFn](methodAddr(f.textClass, "set_Text", 1))
  f.getFont = asProc[GetObjFn](methodAddr(f.textClass, "get_Font", 0))
  f.setTextAlignment = asProc[SetI32Fn](methodAddr(f.textClass, "set_TextAlignment", 1))
  f.setWrap = asProc[SetBoolFn](methodAddr(f.textClass, "set_WrapText", 1))
  if f.setWrap == nil:
    logE("section: TextBlock::WrapText missing; a long caption will clip instead of wrapping")
  f.setHorizontalAlignment = asProc[SetI32Fn](methodAddr(ui, "set_HorizontalAlignment", 1))
  f.setVerticalAlignment = asProc[SetI32Fn](methodAddr(ui, "set_VerticalAlignment", 1))
  f.offTextFont = fieldOffset(f.textClass, "font")
  if f.setTextAlignment == nil or f.offTextFont < 0:
    logE("section: TextAlignment/font missing; the credit will not be styled")
  if f.getVisualChildren == nil or f.getChildren == nil or f.setText == nil:
    logE("section: a required member is missing")
    return false

  let buttonBase = getClass(BUTTON_BASE)
  if buttonBase == nil:
    logE("section: ButtonBase not found, the entry would not be clickable")
    return false
  f.getPressed = asProc[GetBoolFn](methodAddr(buttonBase, "get_IsPressed", 0))
  f.setClickMode = asProc[SetI32Fn](methodAddr(buttonBase, "set_ClickMode", 1))
  f.setVisibility = asProc[SetI32Fn](methodAddr(ui, "set_Visibility", 1))
  f.getVisibility = asProc[GetI32Fn](methodAddr(ui, "get_Visibility", 0))
  f.setEnabled = asProc[SetBoolFn](methodAddr(ui, "set_IsEnabled", 1))
  f.getMouseOver = asProc[GetI32Fn](methodAddr(ui, "get_MouseOverState", 0))

  if f.checkBoxClass != nil:
    f.getToggleState = asProc[GetI32Fn](methodAddrInherited(f.checkBoxClass, "get_State", 0))
    f.setToggleState = asProc[SetI32Fn](methodAddrInherited(f.checkBoxClass, "set_State", 1))
  if f.sliderClass != nil:
    f.getSliderValue = asProc[GetF32Fn](methodAddrInherited(f.sliderClass, "get_Value", 0))
    f.setSliderValue = asProc[SetF32Fn](methodAddrInherited(f.sliderClass, "set_Value", 1))
    f.setSliderMin = asProc[SetF32Fn](methodAddrInherited(f.sliderClass, "set_Minimum", 1))
    f.setSliderMax = asProc[SetF32Fn](methodAddrInherited(f.sliderClass, "set_Maximum", 1))
  if f.getToggleState == nil or f.setToggleState == nil:
    logE("section: ToggleButton::State missing; toggle rows will not reflect or set anything")
  if f.getSliderValue == nil or f.setSliderValue == nil:
    logE("section: Slider::Value missing; slider rows will not reflect or set anything")

  let gameSystem = getClass(GAME_SYSTEM)
  let vdGame = getClass(VD_GAME)
  let soundSystem = getClass(SOUND_SYSTEM)
  f.offGame = if gameSystem == nil: -1 else: fieldOffset(gameSystem, "<Game>k__BackingField")
  f.offSound = if vdGame == nil: -1 else: fieldOffset(vdGame, "<Sound>k__BackingField")
  if soundSystem != nil:
    f.playClick = asProc[VoidFn](methodAddr(soundSystem, "PlayClick", 0))
    f.playMouseOver = asProc[VoidFn](methodAddr(soundSystem, "PlayMouseOver", 0))
  if f.playClick == nil or f.offGame < 0 or f.offSound < 0:
    logE("section: sound system not reachable; the entry will be silent")
  if f.getMouseOver == nil:
    logE("section: MouseOverState missing; the entry will not light on hover")
  f.offMargin = fieldOffset(ui, "MarginInternal")
  if f.setEnabled == nil or f.offMargin < 0:
    logE("section: IsEnabled/margin missing; cloned buttons would stay greyed out")

  f.offDepProps = fieldOffset(ui, "<DependencyProperties>k__BackingField")
  f.offPanelGrid = fieldOffset(getClass(UI_PANEL), "<Grid>k__BackingField")
  f.offTabPanels = fieldOffset(cp, "_tabPanels")
  f.offCurrentTab = fieldOffset(cp, "_currentVisibleTab")
  if f.offCurrentTab < 0:
    logE("section: _currentVisibleTab not found; re-picking the previous tab will not work")
  f.offForceDrawAll = fieldOffset(cp, "_forceDrawAll")

  f.gridBaseClass = getClass(GRID_BASE)
  let container = getClass(PROPERTY_CONTAINER)
  if container != nil:
    f.containerSetObject = asProc[SetObj2Fn](methodAddr(container, "SetObject", 2))
    f.containerGetItem = asProc[GetObj2Fn](methodAddr(container, "get_Item", 1))
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
