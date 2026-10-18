import std/atomics
import ../vdlog, ../mono, hook

## Makes VD's settings page scroll. Its content is taller than the slot it is given once the
## strings are translated - 984 against 936 in French - and nothing in that subtree is a
## scroller, so the last rows are simply unreachable. The bars either side cannot give the
## difference up: they measure 64 and 73 against the 64 and 80 they are allotted.
##
## So a ScrollViewerRubberBand - the control VD already uses on its other tabs - is built and
## takes the settings Grid's place, with the Grid as its content. Three things that are not
## obvious, each learned by watching the live runtime:
##
## 1. Cell placement lives in UIElement.DependencyProperties, a reference type, so the new
##    element points at the Grid's container and lands in the same cell without the
##    attached-property keys being known here.
## 2. Xenko fills in layoutingContext and uiElementServices only once an element takes part in
##    layout. Update() dereferences them, so pumping before they appear segfaults VD.
## 3. VD pumps Update() only on the scrollers it created, and draws dirty regions only. Ours
##    needs the frame tick, and a repaint when it moves - but only when it moves.

const
  CONTROL_PANEL = "VirtualDesktop.Mobile.ControlPanel, VirtualDesktop.Mobile"
  UI_PANEL = "VirtualDesktop.Mobile.UIPanel, VirtualDesktop.Mobile"
  UI_ELEMENT = "Xenko.UI.UIElement, Xenko.UI"
  PANEL = "Xenko.UI.Panels.Panel, Xenko.UI"
  RUBBER_BAND = "Xenko.UI.Controls.ScrollViewerRubberBand, Xenko.UI"
  CONTENT_CONTROL = "Xenko.UI.Controls.ContentControl, Xenko.UI"

  SCROLL_VERTICAL = 2'i32   ## Xenko's ScrollMode
  OFFSET_EPSILON = 0.01'f32 ## below this the offset has not really moved

type
  Vec2 = object
    x, y: cfloat

  Update1Fn = proc(self, arg: pointer) {.cdecl, gcsafe.}
  GetObjFn = proc(self: pointer): pointer {.cdecl, gcsafe.}
  SetObjFn = proc(self, v: pointer) {.cdecl, gcsafe.}
  SetI32Fn = proc(self: pointer, v: int32) {.cdecl, gcsafe.}
  SetBoolFn = proc(self: pointer, v: bool) {.cdecl, gcsafe.}
  SelfFn = proc(self: pointer) {.cdecl, gcsafe.}
  SetItemFn = proc(self: pointer, i: int32, v: pointer) {.cdecl, gcsafe.}
  ## Vector2 comes back in the float registers as an HFA; returning the struct by value lets
  ## the C compiler apply that rule instead of it being hand-decoded here.
  GetVec2Fn = proc(self: pointer): Vec2 {.cdecl, gcsafe.}

  ScrollFeature* = ref object of Feature
    update: Hook
    enabled*: Atomic[bool]

    offSettingsTab, offForceDrawAll, offPanelGrid: int
    offLayoutCtx, offServices, offDepProps: int

    rbClass: MonoClass
    getChildren: GetObjFn
    setContent: SetObjFn
    setScrollMode: SetI32Fn
    setTouch, setRubberBand: SetBoolFn
    rbUpdate: Update1Fn
    rbBarsSize: SelfFn
    getOffsets: GetVec2Fn
    invalidateMeasure, invalidateArrange: SelfFn

    scroller: MonoGCHandle
    attempted: bool
    pumping: bool
    lastX, lastY: float32
    redraws: int

var scrollFeature* = ScrollFeature(name: "settings scroll")

scrollFeature.enabled.store(true)

const
  LIST_ITEMS = 16 ## FastCollection._items
  LIST_SIZE = 24  ## FastCollection._size
  ARRAY_DATA = 32 ## first element of a MonoArray

proc childIndex(items: pointer, count: int, needle: pointer): int =
  for i in 0 ..< count:
    let e = cast[ptr pointer](cast[uint64](items) + uint64(ARRAY_DATA + i * 8))[]
    if e == needle: return i
  -1

proc settingsGrid(self: pointer): pointer =
  let f = scrollFeature
  let tab = readPtrAt(self, f.offSettingsTab)
  if tab == nil: return nil
  readPtrAt(tab, f.offPanelGrid)

## Both are null on a freshly constructed element and are what Update() dereferences.
proc layoutReady(o: pointer): bool =
  let f = scrollFeature
  readPtrAt(o, f.offLayoutCtx) != nil and readPtrAt(o, f.offServices) != nil

proc install(self: pointer): bool =
  let f = scrollFeature
  let grid = settingsGrid(self)
  if grid == nil: return false

  let getParent = cast[GetObjFn](methodAddr(getClass(UI_ELEMENT), "get_Parent", 0))
  if getParent == nil: return false
  let host = getParent(grid)
  if host == nil: return false

  let coll = f.getChildren(host)
  if coll == nil: return false
  let count = int(cast[ptr int32](cast[uint64](coll) + uint64(LIST_SIZE))[])
  let items = cast[ptr pointer](cast[uint64](coll) + uint64(LIST_ITEMS))[]
  if items == nil or count <= 0 or count > 512: return false

  let idx = childIndex(items, count, grid)
  if idx < 0:
    # Already swapped on an earlier pass, or VD rebuilt the tab underneath us.
    return false

  let setItem = cast[SetItemFn](methodAddrInherited(classOf(coll), "set_Item", 2))
  if setItem == nil:
    logE("scroll: no set_Item on the children collection")
    return false

  let sc = newInstance(f.rbClass)
  if sc == nil:
    logE("scroll: could not construct a scroller")
    return false

  # Pin before anything else refers to it; a moving collector would invalidate the handle.
  let handle = pin(sc)
  if handle == 0'u32: return false

  writePtrAt(sc, f.offDepProps, readPtrAt(grid, f.offDepProps))
  if f.setScrollMode != nil: f.setScrollMode(sc, SCROLL_VERTICAL)
  if f.setTouch != nil: f.setTouch(sc, true)
  if f.setRubberBand != nil: f.setRubberBand(sc, true)

  # Replace first, so the Grid is detached before it is re-parented as content.
  setItem(coll, int32(idx), sc)
  f.setContent(sc, grid)
  if f.invalidateMeasure != nil:
    f.invalidateMeasure(sc)
    f.invalidateMeasure(host)
  if f.invalidateArrange != nil: f.invalidateArrange(sc)
  if f.rbBarsSize != nil: f.rbBarsSize(sc)

  f.scroller = handle
  logI("scroll: settings grid wrapped in a scroller at child " & $idx)
  true

proc hookUpdate(self, gameTime: pointer) {.cdecl.} =
  let f = scrollFeature
  guard "ControlPanel.Update":
    if f.enabled.load() and self != nil:
      if f.scroller == 0'u32 and not f.attempted:
        f.attempted = true
        if not install(self): logI("scroll: not installed this launch")

      let sc = moved(f.scroller)
      if sc != nil and gameTime != nil:
        if not f.pumping:
          if layoutReady(sc):
            f.pumping = true
            logI("scroll: layout context ready, pumping")
        if f.pumping and f.rbUpdate != nil:
          f.rbUpdate(sc, gameTime)

          # VD repaints dirty regions only, so a scroll moves the content without the page
          # being redrawn. Forcing it every frame would repaint 90 times a second for nothing,
          # so it is forced only on the frames where the offset actually changed.
          if f.getOffsets != nil:
            let o = f.getOffsets(sc)
            if abs(float32(o.x) - f.lastX) > OFFSET_EPSILON or
               abs(float32(o.y) - f.lastY) > OFFSET_EPSILON:
              f.lastX = float32(o.x)
              f.lastY = float32(o.y)
              writeBoolAt(self, f.offForceDrawAll, true)
              inc f.redraws
              if f.redraws == 1 or f.redraws mod 500 == 0:
                logI("scroll: forced redraw #" & $f.redraws)

  let orig = origAs[Update1Fn](f.update)
  if orig != nil: orig(self, gameTime)

scrollFeature.update = newHook(CONTROL_PANEL, "Update", 1, cast[pointer](hookUpdate))

method install*(f: ScrollFeature): bool =
  if not f.enabled.load():
    logI("settings scroll off: hooks skipped")
    return true

  let cp = getClass(CONTROL_PANEL)
  let panel = getClass(UI_PANEL)
  let ui = getClass(UI_ELEMENT)
  let panelBase = getClass(PANEL)
  let content = getClass(CONTENT_CONTROL)
  f.rbClass = getClass(RUBBER_BAND)
  if cp == nil or panel == nil or ui == nil or panelBase == nil or content == nil or
     f.rbClass == nil:
    logE("scroll: a required class is missing")
    return false

  f.offSettingsTab = fieldOffset(cp, "_settingsTab")
  f.offForceDrawAll = fieldOffset(cp, "_forceDrawAll")
  f.offPanelGrid = fieldOffset(panel, "<Grid>k__BackingField")
  f.offLayoutCtx = fieldOffset(ui, "layoutingContext")
  f.offServices = fieldOffset(ui, "uiElementServices")
  f.offDepProps = fieldOffset(ui, "<DependencyProperties>k__BackingField")
  if f.offSettingsTab < 0 or f.offForceDrawAll < 0 or f.offPanelGrid < 0 or
     f.offLayoutCtx < 0 or f.offServices < 0 or f.offDepProps < 0:
    logE("scroll: field layout not as expected (tab=" & $f.offSettingsTab &
         " draw=" & $f.offForceDrawAll & " grid=" & $f.offPanelGrid &
         " ctx=" & $f.offLayoutCtx & " svc=" & $f.offServices &
         " props=" & $f.offDepProps & ")")
    return false

  f.getChildren = cast[GetObjFn](methodAddr(panelBase, "get_Children", 0))
  f.setContent = cast[SetObjFn](methodAddr(content, "set_Content", 1))
  f.setScrollMode = cast[SetI32Fn](methodAddr(f.rbClass, "set_ScrollMode", 1))
  f.setTouch = cast[SetBoolFn](methodAddr(f.rbClass, "set_TouchScrollingEnabled", 1))
  f.setRubberBand = cast[SetBoolFn](methodAddr(f.rbClass, "set_IsRubberBandEnabled", 1))
  f.rbUpdate = cast[Update1Fn](methodAddr(f.rbClass, "Update", 1))
  f.rbBarsSize = cast[SelfFn](methodAddr(f.rbClass, "UpdateScrollingBarsSize", 0))
  f.getOffsets = cast[GetVec2Fn](methodAddr(f.rbClass, "get_ActualScrollOffsets", 0))
  f.invalidateMeasure = cast[SelfFn](methodAddr(ui, "InvalidateMeasure", 0))
  f.invalidateArrange = cast[SelfFn](methodAddr(ui, "InvalidateArrange", 0))

  if f.getChildren == nil or f.setContent == nil or f.rbUpdate == nil:
    logE("scroll: children/content/update not resolvable")
    return false
  if f.getOffsets == nil:
    # Without it the redraw cannot be limited to frames that moved, and forcing one every
    # frame is worse than leaving this alone.
    logE("scroll: get_ActualScrollOffsets missing, skipping")
    return false

  if not f.update.install(cp):
    logE("scroll: ControlPanel::Update hook failed")
    return false

  logI("hooked ControlPanel::Update for settings scrolling")
  true
