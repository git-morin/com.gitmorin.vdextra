include nemohooks/features

import std/atomics
import nemohooks
import nemohooks/backends/mono
import ../xenko, ../settings, ../fontmap, loadcontent, panelupdate

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
  GAME_SYSTEM = "VirtualDesktop.Mobile.GameSystem, VirtualDesktop.Mobile"
  VD_GAME = "VirtualDesktop.Mobile.Game, VirtualDesktop.Mobile"
  SOUND_SYSTEM = "VirtualDesktop.Mobile.SoundSystem, VirtualDesktop.Mobile"
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

  ## Xenko reports no hover as MouseOverState.MouseOverNone; anything else is over the element
  ## or one of its children, and VD treats both the same way.
  MOUSE_OVER_NONE = 0'i32

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

  ## A description is a TextBlock indented under the control it belongs to (VD uses 59); a
  ## section header is one flush with the column's edge. The indent is what tells them apart.
  NOTE_INDENT = 40.0

  ## Our rows are cloned from templates the fit pass has already trimmed, so they arrive with
  ## almost no spacing and a description ends up touching the row beneath it. This is the gap
  ## each row is guaranteed, raised to rather than added, so a row that already has room keeps
  ## what it was given.
  ROW_GAP = 8.0'f32

  ## What VD paints an enabled button's caption (UIColors.ButtonTextColor, 160/160/160). A
  ## template cloned from a row VD had disabled carries the dark grey instead, which is what
  ## made every button on the page look dead.
  BUTTON_TEXT_COLOR = 0xFFA0A0A0'u32

  ## Xenko.UI.ToggleState, read off the engine source rather than assumed: Checked is **0** and
  ## UnChecked is **2**, with Indeterminate between them. Guessing the usual
  ## indeterminate-first order would have inverted every toggle on the page.
  TOGGLE_CHECKED = 0'i32
  TOGGLE_UNCHECKED = 2'i32

  ## A clone carries no event handlers, so a change is noticed by comparing against what we
  ## last saw rather than by subscribing. Slider values are floats the user drags, so a change
  ## has to clear a threshold to count - a tick of VD's own is far coarser than this.
  VALUE_EPSILON = 0.001'f32

  ## One per bound row; the page has far fewer, and overrunning this only drops bindings.
  MAX_BOUND_ROWS = 24

  ## Xenko.Graphics.TextAlignment is Left, Center, Right, so Right is 2. This is the text's
  ## position *within* the block, which is the one that matters: a note stretches to the
  ## column's width, so setting the element's own HorizontalAlignment moved nothing.
  TEXT_ALIGN_RIGHT = 2'i32

  ## The credit, at the end of the right-hand column. Two short lines rather than one long one:
  ## the column is narrow enough that a single line wraps, and an automatic break lands in the
  ## middle of the name.
  ##
  ## VD's own fonts are per-size sprite sheets that stop at Latin, so the heart is drawn only
  ## when some font actually carries the glyph - the full-coverage one the font feature captures
  ## for translations, if it has it. Otherwise the line degrades to "<3" rather than a box.
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

  ## VD's own row vocabulary, read off its settings page: a column is a flat list of these.
  ## A CheckBox *is* the row and carries its own caption, so a description has to be a row of
  ## its own - which is why our toggle descriptions had nowhere to go when every row was
  ## assumed to hold two labels.
  RowKind = enum
    rkHeader, rkToggle, rkNote, rkSlider, rkButton

  PageRow = tuple[column: int, kind: RowKind, setting: Setting, text: string]

  ## A row whose control stands for a setting. `seen` is the control's value as of the last
  ## poll: the user is the only other thing that changes it, so any difference is their edit.
  BoundRow = object
    control: pointer
    setting: Setting
    kind: RowKind
    seen: float32
    ## The label beside a slider's track. VD fills its own from a handler cloning drops, so
    ## ours is written here or it never changes.
    valueLabel: pointer

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

    ## The rows that stand for a setting, polled for the user's edits.
    bound: array[MAX_BOUND_ROWS, BoundRow]
    boundCount: int
    getToggleState: GetI32Fn
    setToggleState: SetI32Fn
    getSliderValue: GetF32Fn
    setSliderValue: SetF32Fn
    setSliderMin, setSliderMax: SetF32Fn

    ## VD's own rows, cloned once per row we draw.
    headerModel, toggleModel, noteModel, sliderModel, buttonModel: pointer
    setEnabled: SetBoolFn
    offMargin: int
    navEntries: pointer ## VD's nav collection, for the active highlight
    activeColor, inactiveColor: uint32
    getVisibility: GetI32Fn
    containerSetObject: SetObj2Fn
    containerGetItem: GetObj2Fn
    gridBaseClass: MonoClass
    rowKey, columnKey: MonoObject
    offDepProps, offPanelGrid, offTabPanels, offCurrentTab: int
    offForceDrawAll: int
    content: pointer ## our tab's grid, pinned
    showing, wasShowing: bool
    redrawFrames: int
    entry: pointer ## our nav button, pinned
    wasPressed: bool
    wasOver: bool
    getMouseOver: GetI32Fn
    playClick, playMouseOver: VoidFn
    offGame, offSound: int

    offGridMain: int
    buttonClass, textClass: MonoClass
    getFont: GetObjFn
    setTextAlignment: SetI32Fn
    offTextFont: int
    version: string
    checkBoxClass, sliderClass: MonoClass
    settingsTabClass: MonoClass
    getVisualChildren: GetObjFn
    getChildren: GetObjFn
    setText: SetStrFn
    cloneMethod: MonoMethod ## UICloner.Clone - static, one UIElement in, a deep copy out
    applied: bool

var sectionFeature* = SectionFeature(name: "vdextra section")

sectionFeature.enabled.store(true)

## The module's options, laid out in VD's own idiom: a header, the control, and a description
## indented under it. Every control here drives its setting directly.
##
## Only settings this page can actually change belong on it. The rest - music source, UI
## language, update channel, which cue sounds to mute - need Android work no hook can do from
## inside VD, so they stay in the companion app and are named at the bottom rather than shown
## as buttons that do nothing when pressed.
const PAGE_ROWS: array[19, PageRow] = [
  (0, rkHeader, stNone, "VDExtra"),
  (0, rkToggle, stFit, "Fit long settings pages"),
  (0, rkNote, stNone, "Tighten row spacing so a translated page stops hiding its last rows"),
  (0, rkNote, stNone, "Applied while the panel is built, so restart VD to see this change"),
  (0, rkHeader, stNone, "Sound"),
  (0, rkSlider, stMusicVolume, "Background music volume"),
  (0, rkToggle, stNoPerfSound, "Disable performance cue sounds"),
  (0, rkNote, stNone, "Mute the cues played when streaming quality changes"),

  (1, rkHeader, stNone, "Bitrate"),
  (1, rkToggle, stBitrateExtend, "Extend bitrate range"),
  (1, rkNote, stNone, "Raise the bitrate ceiling above the stock limit"),
  (1, rkSlider, stBitrateScale, "Bitrate ceiling multiplier"),
  (1, rkToggle, stBitrateUnlock, "Remove auto speed-test bitrate cap"),
  (1, rkNote, stNone, "Skip the bandwidth cap applied after the speed test"),
  (1, rkHeader, stNone, "Network"),
  (1, rkToggle, stForceLan, "Force LAN discovery"),
  (1, rkNote, stNone, "Still show local PCs even when the server is unreachable"),
  (1, rkHeader, stNone, "In the VDExtra app"),
  (1, rkNote, stNone, "Music source, UI language, update channel and cue sound choice")
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
  asProc[AddFn](resolveMethod(coll, "Add", 1))

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

## Every row kind keeps its caption in its first label, read in tree order: a CheckBox's own
## content, a slider row's title above the track, a button's caption, or - for a header or a
## description - the row itself, which is already a TextBlock.
proc retextRow(row: pointer, text: string) =
  var labels {.noinit.}: array[MAX_ROW_LABELS, pointer]
  var n = 0
  collectLabels(row, 0, labels, n)
  if n > 0: setLabel(labels[0], text)

## A template cloned from a row VD had disabled stays disabled - it cannot be pressed and its
## caption keeps the dark grey. VD re-enables a control by setting both, so this does too.
proc enableRow(row: pointer) =
  let f = sectionFeature
  if f.setEnabled != nil: f.setEnabled(row, true)
  let btn = firstOfClass(row, f.buttonClass, 0)
  if btn == nil: return
  if f.setEnabled != nil: f.setEnabled(btn, true)
  setTextColorAt(firstTextBlock(btn, 0), BUTTON_TEXT_COLOR)

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

## VD's button rows sit indented beneath the control they belong to, so a button cloned out of
## one and stood on its own lands out of line with the toggles. Both edges are settled here:
## the indent is matched to the toggle template, and every row is given room to breathe.
proc spaceRow(row: pointer, kind: RowKind) =
  let f = sectionFeature
  if marginAt(row, THICKNESS_BOTTOM) < ROW_GAP:
    setMarginAt(row, THICKNESS_BOTTOM, ROW_GAP)
  if kind == rkButton and f.toggleModel != nil:
    setMarginAt(row, THICKNESS_LEFT, marginLeft(f.toggleModel))

## The control a bound row's value lives on: the CheckBox itself for a toggle, the track for a
## slider. Found by class so a template whose tree VD rearranges still binds.
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

## Puts the setting's current value on screen. The clone arrives carrying whatever VD's own row
## showed, so without this a toggle reads as VD's value rather than ours.
proc showValue(b: BoundRow, v: float32) =
  let f = sectionFeature
  if b.valueLabel != nil: setLabel(b.valueLabel, format(b.setting, v))
  case b.kind
  of rkToggle:
    if f.setToggleState != nil:
      f.setToggleState(b.control, if v >= 0.5'f32: TOGGLE_CHECKED else: TOGGLE_UNCHECKED)
  of rkSlider:
    # Bounds first: set_Value clamps to them, so a value outside the template's range would be
    # trimmed on the way in and read back as something the user never chose.
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
  # Pinned for the same reason cloneOf pins a row: the address is held across frames, and
  # pinning the row does not pin the control nested inside it.
  discard pin(control)
  var b = BoundRow(control: control, setting: setting, kind: kind, seen: 0'f32)
  if kind == rkSlider:
    var labels {.noinit.}: array[MAX_ROW_LABELS, pointer]
    var n = 0
    collectLabels(row, 0, labels, n)
    # Label zero is the caption retextRow has already written, so the value is the next one.
    if n >= 2:
      b.valueLabel = labels[1]
      discard pin(b.valueLabel) # held across frames, like the control
    else:
      logE("section: " & $setting & " slider row has no value label")
  let v = readValue(setting)
  let before = if kind == rkToggle and f.getToggleState != nil:
                 f.getToggleState(control) else: -1'i32
  showValue(b, v)
  # Read back rather than trusting the write: a slider clamps, and starting from the clamped
  # value is what stops the first poll from reporting a change the user did not make.
  b.seen = controlValue(b)
  let after = if kind == rkToggle and f.getToggleState != nil:
                f.getToggleState(control) else: -1'i32
  logI("section: bound " & $setting & " want=" & describe(setting, v) &
       " got=" & describe(setting, b.seen) &
       (if kind == rkToggle: " rawState " & $before & "->" & $after else: ""))
  f.bound[f.boundCount] = b
  inc f.boundCount

## Pushed down from Kotlin, which is the only side that knows the APK's version.
proc setVersion*(v: string) =
  sectionFeature.version = v

## True when `font` can draw every character of `text`. Without this the heart would be a box
## on any build whose fonts stop at Latin.
proc fontHas(font: pointer, text: string): bool =
  if font == nil: return false
  var units: seq[uint16] = @[]
  utf8ToUtf16(text, units)
  if units.len == 0: return false
  fontCovers(font, cast[ptr UncheckedArray[uint16]](addr units[0]), units.len)

## The font to draw the credit's heart with, or nil to keep the note's own and spell it "<3".
## Written as a field rather than through set_Font, which the text feature intercepts and
## discards.
proc heartFont(): pointer =
  let f = sectionFeature
  if f.getFont == nil or f.noteModel == nil or f.offTextFont < 0: return nil
  let own = f.getFont(f.noteModel)
  if fontHas(own, HEART): return own # nothing to swap, it already has it
  let full = pickReplacement(fontSize(own))
  if full != nil and fontHas(full, HEART): return full
  nil

proc applyCreditStyle(row: pointer, font: pointer) =
  let f = sectionFeature
  let label = firstTextBlock(row, 0)
  if label == nil: return
  if f.setTextAlignment != nil: f.setTextAlignment(label, TEXT_ALIGN_RIGHT)
  if font != nil and f.offTextFont >= 0: writePtrAt(label, f.offTextFont, font)

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
  # The clone inherits the model's state - a ticked checkbox, a slider part-way along - which
  # is VD's value, not ours. bindRow overwrites it for the rows that stand for a setting.
  if f.setVisibility != nil: f.setVisibility(result, VISIBILITY_VISIBLE)
  enableRow(result)
  spaceRow(result, kind)
  retextRow(result, text)
  if kind == rkButton: rememberButton(result, text)
  bindRow(result, kind, setting)

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

## Walks every visible row of every column on the settings page. Collapsed rows are skipped:
## SettingsTab hides the ones this headset does not support, and a hidden template clones into
## a row that draws nothing.
## Nimony treats an iterator as noSideEffect unless told otherwise; this one reads the
## feature's resolved entry points, which are globals.
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

## The first row holding a `cls` control. A row is the unit VD's asset styles, so cloning one
## brings its label, its spacing and its chrome along together - which is what makes our page
## match theirs without a single measurement being copied.
proc findRowTemplate(grid: pointer, cls: MonoClass): pointer =
  if cls == nil: return nil
  for row in settingsRows(grid):
    if firstOfClass(row, cls, 0) != nil: return row
  nil

## A bare TextBlock row is either a section header or a description, and only the indent says
## which: VD flushes headers with the column edge and pushes descriptions in under the control
## they explain.
proc findTextTemplate(grid: pointer, indented: bool): pointer =
  let f = sectionFeature
  for row in settingsRows(grid):
    if classOf(row) == f.textClass and (marginLeft(row) >= NOTE_INDENT) == indented:
      return row
  nil

## Fills one emptied column with the rows assigned to it.
proc fillColumn(col: pointer, index: int): int =
  result = 0
  let f = sectionFeature
  let kids = f.getChildren(col)
  let clear = resolveMethod(kids, "Clear", 0)
  let add = resolveAdd(kids)
  if clear == nil or add == nil: return 0
  asProc[VoidFn](clear)(kids)
  for spec in PAGE_ROWS:
    if spec.column == index:
      let row = buildRow(spec.kind, spec.text, spec.setting)
      if row != nil:
        add(kids, row)
        inc result
  if index == 1:
    let font = heartFont()
    let heart = if font != nil: HEART else: HEART_FALLBACK
    logI("section: credit heart=" & (if font != nil: "glyph" else: "ascii"))
    var lines: array[2, string]
    lines[0] = SECTION_NAME & " " & f.version
    lines[1] = "Made with " & heart & CREDIT_BY
    for i in 0 .. 1:
      if i == 0 and f.version.len == 0: continue
      let credit = buildRow(rkNote, lines[i], stNone)
      if credit != nil:
        applyCreditStyle(credit, if i == 1: font else: nil)
        add(kids, credit)
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
  for i in 0 ..< n:
    let child = childAt(kids, i)
    if child == nil: continue
    if not isColumn(child):
      # An overlay of VD's, with no meaning on our page and nothing to show it.
      if f.setVisibility != nil: f.setVisibility(child, VISIBILITY_COLLAPSED)
      continue
    filled += fillColumn(child, columns)
    inc columns
    if columns >= 2: break

  logI("section: page has " & $columns & " column(s), " & $filled & " row(s), " &
       $f.pageButtonCount & " button(s)")
  if filled == 0: return nil

  if f.setVisibility != nil: f.setVisibility(page, VISIBILITY_HIDDEN)
  page

## VD plays both of the nav's sounds from handlers a clone does not carry: PlayClick from
## LeftPanel.OnTabButtonClick, PlayMouseOver from UIPanel.OnElementMouseOverStateChanged. The
## sound system is reached through the panel rather than cached, since two pointer reads cost
## nothing and a cached one would have to be pinned against a moving collector.
proc playCue(self: pointer, cue: VoidFn) =
  let f = sectionFeature
  if cue == nil or f.offGame < 0 or f.offSound < 0: return
  let game = readPtrAt(self, f.offGame)
  if game == nil: return
  let sound = readPtrAt(game, f.offSound)
  if sound != nil: cue(sound)

## True while the user is pressing one of VD's own nav entries. Watching for this is what lets
## us step aside even when VD itself will do nothing - see standDown.
proc vdEntryPressed(): bool =
  let f = sectionFeature
  if f.navEntries == nil or f.getPressed == nil: return false
  let n = childCount(f.navEntries)
  if n <= 0 or n > MAX_TABS: return false
  for i in 0 ..< n:
    let btn = childAt(f.navEntries, i)
    if btn != nil and btn != f.entry and f.getPressed(btn): return true
  false

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
## VD's rule, from LeftPanel.UpdateTabButtonColors: an entry is white when it is the selected
## tab *or* the pointer is over it, and grey otherwise. Repeating the hover half matters -
## while our page owns the panel we repaint VD's entries every frame, and painting them flatly
## grey wiped out the highlight VD had just given the one under the pointer.
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
    # Entries VD does not know are ours are left alone unless our page owns the panel: while it
    # does, VD still paints its own idea of which tab is selected, and this overrides it.
    if btn == f.entry:
      setTextColorAt(text, navColor(btn, f.showing))
    elif f.showing:
      setTextColorAt(text, navColor(btn, false))

## Hands the panel back to VD.
##
## Simply clearing the flag is not enough. OnSelectedTabChanged is the only thing that ever
## makes a tab grid visible, and it runs only when SelectedTab actually *changes* - so picking
## the tab that was open before ours raises no event, and the page VD believes is up stays
## hidden behind ours. Whichever tab VD still considers current is shown explicitly here.
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

  # The bound rows. A clone carries no handlers, so the control is simply compared against
  # what it read last poll: Xenko toggles a CheckBox and moves a Slider from its own touch
  # handling, which are virtual overrides rather than the delegates cloning drops - so the
  # control has already changed itself by the time this sees it, and the only thing left to do
  # is pass the new value on.
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
      # VD paints only what it believes changed and knows nothing about our controls, so
      # without this the state changes and the screen keeps showing the old one. This is the
      # same flag a page transition needs, for the same reason.
      f.redrawFrames = REDRAW_FRAMES
      # A drag reports a change on most frames, so sliders trace at debug level and only the
      # discrete toggles are worth a line in the normal log.
      if b.kind == rkSlider: logD("section: " & $b.setting & " = " & describe(b.setting, v))
      else: logI("section: " & $b.setting & " = " & describe(b.setting, v))

  # The page's own buttons, read only while the page is up so a press somewhere else cannot be
  # attributed to one of ours.
  for i in 0 ..< f.pageButtonCount:
    let btn = f.pageButtons[i]
    if btn == nil: continue
    let held = f.showing and f.getPressed(btn)
    if held != f.pageButtonHeld[i]:
      # Pressing a button swaps its sprite, which needs the same repaint a value change does.
      f.redrawFrames = REDRAW_FRAMES
      if held: logI("section: " & f.pageButtonNames[i] & " clicked")
    f.pageButtonHeld[i] = held

  flushIfSettled()

  syncContent(self)
  syncNavHighlight()
  if f.showing != f.wasShowing:
    f.wasShowing = f.showing
    # Leaving the page is the last chance to save before VD is quit from somewhere else, so a
    # pending write goes out now rather than waiting for the drag to settle.
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

  # Panel.Children, not VisualChildren: MeasureOverride and ArrangeOverride iterate Children,
  # so an element added only to the visual tree draws but is never measured, arranged or
  # hit-tested - which is exactly 0x0 size, wrong position, and no response to clicks.
  let entries = f.getChildren(stack)
  # Not entry zero: VD's first nav button is 89 tall against the others' 81, so a clone of it
  # stands out by the difference. Any later one is a typical entry.
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

  f.getVisualChildren = asProc[GetObjFn](methodAddr(ui, "get_VisualChildren", 0))
  f.getChildren = asProc[GetObjFn](methodAddr(getClass(PANEL), "get_Children", 0))
  f.setText = asProc[SetStrFn](methodAddr(f.textClass, "set_Text", 1))
  f.getFont = asProc[GetObjFn](methodAddr(f.textClass, "get_Font", 0))
  f.setTextAlignment = asProc[SetI32Fn](methodAddr(f.textClass, "set_TextAlignment", 1))
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

  # State lives on ToggleButton and Value on Slider, both above the classes the rows are found
  # by, so these walk up rather than asking the leaf class.
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
