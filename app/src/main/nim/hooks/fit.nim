## Raw interop; see the nemohooks module docs for why these two features are on.
when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "assumeSync".}

import std/[atomics, strutils]
import nemohooks
import ../xenko, loadcontent

## Makes VD's control panel pages fit the space they are given, so their last rows stop being
## unreachable and their descriptions stop landing on the control below.
##
## Translated strings make the two settings columns 956 tall in a 936 cell. Correcting that
## after the fact is impossible: VD measures this layout exactly once and never again - a margin
## write plus InvalidateMeasure on the row, the column and the grid left the desired height at
## 956 across hundreds of frames. So the only place a size change can land is before that single
## pass, which is why this hooks LoadContent rather than Update or Draw.
##
## The module is loaded from mono.android.Runtime.initInternal, far earlier than anything can
## attach from outside, which is the only reason this hook point is reachable at all.

const
  UI_PANEL = "VirtualDesktop.Mobile.UIPanel, VirtualDesktop.Mobile"
  UI_ELEMENT = "Xenko.UI.UIElement, Xenko.UI"
  PANEL = "Xenko.UI.Panels.Panel, Xenko.UI"
  TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"


  ## A column is the settings list; the overlay grids hold a single explicitly sized child.
  MIN_COLUMN_ROWS = 2

  ## Below this a description fits its row whatever the language, so leave VD's choice alone.
  WRAP_MIN_CHARS = 28
  WALK_DEPTH = 6

  ## Wrapping buys correctness but costs height: with it on, the left column measured 980 in the
  ## 920 it is given, because a few descriptions legitimately gained a line. This pays for that
  ## out of row spacing rather than out of the translations. Taken from both edges so the gap
  ## shrinks evenly - 5px off one edge alone only found 35 of the 60px needed, since half the
  ## rows lead with no top margin at all.
  ROW_TRIM = 4'f32

  ## Edge order comes from mono.nim; Xenko's Thickness is not ordered left/top/right/bottom.
  M_LEFT = THICKNESS_LEFT
  M_TOP = THICKNESS_TOP
  M_BOTTOM = THICKNESS_BOTTOM

type
  GetObjFn = proc(self: pointer): pointer {.cdecl, gcsafe.}
  GetBoolFn = proc(self: pointer): bool {.cdecl, gcsafe.}
  SetBoolFn = proc(self: pointer, v: bool) {.cdecl, gcsafe.}

  FitFeature* = ref object of Feature
    enabled*: Atomic[bool]
    pad*: Atomic[float32] ## smallest left and top margin a column may end up with

    offTabPanels, offPanelGrid, offMargin: int
    getChildren: GetObjFn
    getVisualChildren: GetObjFn
    getText: GetObjFn
    getWrap: GetBoolFn
    setWrap: SetBoolFn
    textBlockClass: MonoClass
    applied: bool
    wrapped: int

var fitFeature* = FitFeature(name: "settings fit")

fitFeature.enabled.store(true)
fitFeature.pad.store(16.0'f32)

proc marginAt(o: pointer, edge: int): float32 =
  let off = fitFeature.offMargin
  if o == nil or off < 0: return 0'f32
  cast[ptr float32](cast[uint64](o) + uint64(off + edge * 4))[]

proc setMarginAt(o: pointer, edge: int, v: float32) =
  let off = fitFeature.offMargin
  if o == nil or off < 0: return
  cast[ptr float32](cast[uint64](o) + uint64(off + edge * 4))[] = v

## Spends the column's bottom margin, which is dead space below the list. Row spacing is never
## touched: taking a slice off every row made the page look cramped and bought little.
proc reclaim(col: pointer): float32 =
  let b = marginAt(col, M_BOTTOM)
  if b <= 0'f32: return 0'f32
  setMarginAt(col, M_BOTTOM, 0'f32)
  b

## Normalises the left and top margin to `pad` rather than only raising it. The columns start
## inconsistent - one has a 43px top margin, the other 16 - and levelling them both buys the
## slack the bottom margins alone do not: 40px left the content exactly 936 tall, with nothing
## spare for the last row's button. Returns how much height this gave back.
proc padEdges(col: pointer): float32 =
  let want = fitFeature.pad.load()
  result = marginAt(col, M_TOP) - want
  if result < 0'f32: result = 0'f32
  setMarginAt(col, M_LEFT, want)
  setMarginAt(col, M_TOP, want)

## Takes `ROW_TRIM` off each row's gap, top and bottom, never below zero. A row whose margin is
## already smaller gives what it has rather than being pushed into its neighbour.
proc trimRows(col: pointer): float32 =
  result = 0'f32
  let f = fitFeature
  let kids = f.getChildren(col)
  let n = childCount(kids)
  if n <= 0 or n > 512: return 0'f32
  for i in 0 ..< n:
    let row = childAt(kids, i)
    if row == nil: continue
    for edge in [M_TOP, M_BOTTOM]:
      let m = marginAt(row, edge)
      if m <= 0'f32: continue
      let take = min(m, ROW_TRIM)
      setMarginAt(row, edge, m - take)
      result += take

proc isTextBlock(o: pointer): bool =
  let target = fitFeature.textBlockClass
  if o == nil or target == nil or pClassGetParent == nil: return false
  var k = classOf(o)
  for _ in 0 ..< 8:
    if k == nil: break
    if k == target: return true
    k = pClassGetParent(k)
  false

proc textLength(o: pointer): int =
  let f = fitFeature
  if f.getText == nil: return 0
  let s = f.getText(o)
  if s == nil: return 0
  monoStrLen(s)

## VD sets WrapText on some descriptions and not others. The ones without it render as a single
## long line that runs over the next control - which English never exposed, because its strings
## were short enough either way. Turning it on here, before the one measure, lets the row size
## itself for the wrapped text instead of a translation having to be short enough to fit.
proc enableWrap(el: pointer, depth: int) =
  let f = fitFeature
  if el == nil or depth > WALK_DEPTH: return
  if isTextBlock(el) and f.getWrap != nil and f.setWrap != nil:
    if textLength(el) >= WRAP_MIN_CHARS and not f.getWrap(el):
      f.setWrap(el, true)
      inc f.wrapped
  if f.getVisualChildren == nil: return
  let kids = f.getVisualChildren(el)
  let n = childCount(kids)
  if n <= 0 or n > 512: return
  for i in 0 ..< n:
    enableWrap(childAt(kids, i), depth + 1)

## Every page gets the same treatment: wrap the descriptions VD left unwrapped, then pay for the
## height that costs out of the column's own dead space and its row gaps. Pages that already
## scroll are included - they simply end up needing less scrolling.
proc fitPage(grid: pointer, label: string) =
  let f = fitFeature
  let cols = f.getChildren(grid)
  let n = childCount(cols)
  if n <= 0 or n > 512: return

  var reclaimed = 0'f32
  var touched = 0
  for i in 0 ..< n:
    let col = childAt(cols, i)
    if col == nil: continue
    let rows = childCount(f.getChildren(col))

    # The overlay grids are a single explicitly sized child and are not what gets cut off.
    if rows < MIN_COLUMN_ROWS: continue

    enableWrap(col, 0)
    reclaimed += reclaim(col) + padEdges(col) + trimRows(col)
    inc touched

  logI("fit: " & label & " " & $touched & " column(s), reclaimed " &
       formatFloat(reclaimed, ffDecimal, 0) & "px")

proc onPanelLoaded(self: pointer) {.nimcall.} =
  let f = fitFeature
  if not f.enabled.load() or f.applied or self == nil: return
  let tabs = readPtrAt(self, f.offTabPanels)
  if tabs == nil:
    logI("fit: no tab panels at LoadContent exit")
    return
  f.applied = true

  let count = childCount(tabs)
  if count <= 0 or count > 64:
    logE("fit: implausible tab count " & $count)
    return

  for i in 0 ..< count:
    let tab = arrayAt(tabs, i)
    if tab == nil: continue
    let grid = readPtrAt(tab, f.offPanelGrid)
    if grid == nil: continue
    fitPage(grid, className(classOf(tab)))

  logI("fit: " & $count & " tab(s) done, wrapped " & $f.wrapped & " label(s)")

method install*(f: FitFeature): bool =
  if not f.enabled.load():
    logI("settings fit off: hook skipped")
    return true

  let cp = getClass(CONTROL_PANEL)
  let panel = getClass(UI_PANEL)
  let ui = getClass(UI_ELEMENT)
  let panelBase = getClass(PANEL)
  if cp == nil or panel == nil or ui == nil or panelBase == nil:
    logE("fit: a required class is missing")
    return false

  f.offTabPanels = fieldOffset(cp, "_tabPanels")
  f.offPanelGrid = fieldOffset(panel, "<Grid>k__BackingField")
  f.offMargin = fieldOffset(ui, "MarginInternal")
  if f.offTabPanels < 0 or f.offPanelGrid < 0 or f.offMargin < 0:
    logE("fit: field layout not as expected (tabs=" & $f.offTabPanels &
         " grid=" & $f.offPanelGrid & " margin=" & $f.offMargin & ")")
    return false

  f.getChildren = asProc[GetObjFn](methodAddr(panelBase, "get_Children", 0))
  f.getVisualChildren = asProc[GetObjFn](methodAddr(ui, "get_VisualChildren", 0))
  f.textBlockClass = getClass(TEXT_BLOCK)
  if f.textBlockClass != nil:
    f.getText = asProc[GetObjFn](methodAddr(f.textBlockClass, "get_Text", 0))
    f.getWrap = asProc[GetBoolFn](methodAddr(f.textBlockClass, "get_WrapText", 0))
    f.setWrap = asProc[SetBoolFn](methodAddr(f.textBlockClass, "set_WrapText", 1))
  if f.setWrap == nil or f.getWrap == nil or f.getText == nil:
    logE("fit: TextBlock wrap members missing, long labels will still overflow")
  if f.getChildren == nil:
    logE("fit: Panel::get_Children not resolvable")
    return false

  if not installLoadContent(): return false
  onLoadContent(onPanelLoaded)

  logI("registered the page fit pass")
  true
