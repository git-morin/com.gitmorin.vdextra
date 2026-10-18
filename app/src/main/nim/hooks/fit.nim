import std/[atomics, strutils]
import ../vdlog, ../mono, hook

## Makes VD's settings page fit the space it is given, so its last rows stop being unreachable.
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
  CONTROL_PANEL = "VirtualDesktop.Mobile.ControlPanel, VirtualDesktop.Mobile"
  UI_PANEL = "VirtualDesktop.Mobile.UIPanel, VirtualDesktop.Mobile"
  UI_ELEMENT = "Xenko.UI.UIElement, Xenko.UI"
  PANEL = "Xenko.UI.Panels.Panel, Xenko.UI"

  CELL_HEIGHT = 936'f32 ## the content row of VD's root grid, measured live
  REPORT_ROWS = 4       ## rows described per column before going quiet

  ## A column is the settings list; the overlay grids hold a single explicitly sized child.
  MIN_COLUMN_ROWS = 2

  ## Thickness is six floats: left, top, right, bottom, front, back.
  M_LEFT = 0
  M_TOP = 1
  M_BOTTOM = 3

type
  VoidRetFn = proc(self: pointer) {.cdecl, gcsafe.}
  GetObjFn = proc(self: pointer): pointer {.cdecl, gcsafe.}
  GetF32Fn = proc(self: pointer): cfloat {.cdecl, gcsafe.}

  FitFeature* = ref object of Feature
    loadContent: Hook
    enabled*: Atomic[bool]
    pad*: Atomic[float32] ## smallest left and top margin a column may end up with

    offSettingsTab, offPanelGrid, offMargin: int
    getChildren: GetObjFn
    getHeight: GetF32Fn
    applied: bool

var fitFeature* = FitFeature(name: "settings fit")

fitFeature.enabled.store(true)
fitFeature.pad.store(16.0'f32)

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

proc marginAt(o: pointer, edge: int): float32 =
  let off = fitFeature.offMargin
  if o == nil or off < 0: return 0'f32
  cast[ptr float32](cast[uint64](o) + uint64(off + edge * 4))[]

proc setMarginAt(o: pointer, edge: int, v: float32) =
  let off = fitFeature.offMargin
  if o == nil or off < 0: return
  cast[ptr float32](cast[uint64](o) + uint64(off + edge * 4))[] = v

proc heightOf(o: pointer): string =
  let f = fitFeature
  if f.getHeight == nil or o == nil: return "?"
  let h = float32(f.getHeight(o))
  if h != h: "auto" else: formatFloat(h, ffDecimal, 0)

proc describe(o: pointer): string =
  "H=" & heightOf(o) & " margin[l=" & formatFloat(marginAt(o, M_LEFT), ffDecimal, 0) &
    " t=" & formatFloat(marginAt(o, M_TOP), ffDecimal, 0) &
    " b=" & formatFloat(marginAt(o, M_BOTTOM), ffDecimal, 0) & "]"

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

proc hookLoadContent(self: pointer) {.cdecl.} =
  let f = fitFeature
  let orig = origAs[VoidRetFn](f.loadContent)
  if orig != nil: orig(self)

  guard "ControlPanel.LoadContent":
    if not f.enabled.load() or f.applied or self == nil: return
    let tab = readPtrAt(self, f.offSettingsTab)
    if tab == nil:
      logI("fit: settings tab not built yet at LoadContent exit")
      return
    let grid = readPtrAt(tab, f.offPanelGrid)
    if grid == nil:
      logI("fit: settings grid still null")
      return
    f.applied = true

    let cols = f.getChildren(grid)
    let n = childCount(cols)
    logI("fit: settings grid " & describe(grid) & " with " & $n & " child(ren)")
    if n <= 0 or n > 512: return

    var reclaimed = 0'f32
    for i in 0 ..< n:
      let col = childAt(cols, i)
      if col == nil: continue
      let kids = f.getChildren(col)
      let rows = childCount(kids)

      # The overlay grids are a single explicitly sized child and are not what gets cut off.
      if rows < MIN_COLUMN_ROWS:
        logI("fit:   col[" & $i & "] skipped, " & $rows & " row(s)")
        continue

      for j in 0 ..< min(rows, REPORT_ROWS):
        let row = childAt(kids, j)
        if row != nil:
          logI("fit:     row[" & $j & "] " & describe(row))

      let fromBottom = reclaim(col)
      let fromTop = padEdges(col)
      reclaimed += fromBottom + fromTop
      logI("fit:   col[" & $i & "] rows=" & $rows & " reclaimed " &
           formatFloat(fromBottom, ffDecimal, 0) & "px bottom + " &
           formatFloat(fromTop, ffDecimal, 0) & "px top, now " & describe(col))

    logI("fit: reclaimed " & formatFloat(reclaimed, ffDecimal, 0) &
         "px against a " & formatFloat(CELL_HEIGHT, ffDecimal, 0) & "px cell")

fitFeature.loadContent = newHook(CONTROL_PANEL, "LoadContent", 0, cast[pointer](hookLoadContent))

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

  f.offSettingsTab = fieldOffset(cp, "_settingsTab")
  f.offPanelGrid = fieldOffset(panel, "<Grid>k__BackingField")
  f.offMargin = fieldOffset(ui, "MarginInternal")
  if f.offSettingsTab < 0 or f.offPanelGrid < 0 or f.offMargin < 0:
    logE("fit: field layout not as expected (tab=" & $f.offSettingsTab &
         " grid=" & $f.offPanelGrid & " margin=" & $f.offMargin & ")")
    return false

  f.getChildren = cast[GetObjFn](methodAddr(panelBase, "get_Children", 0))
  f.getHeight = cast[GetF32Fn](methodAddr(ui, "get_Height", 0))
  if f.getChildren == nil:
    logE("fit: Panel::get_Children not resolvable")
    return false

  if not f.loadContent.install(cp):
    logE("fit: ControlPanel::LoadContent hook failed")
    return false

  logI("hooked ControlPanel::LoadContent to fit the settings page")
  true
