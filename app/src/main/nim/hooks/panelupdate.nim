import ../vdlog, ../mono, hook, loadcontent

## Shared owner of ControlPanel.Update, the panel's per-frame tick.
##
## Same arrangement as loadcontent: Dobby installs one hook per address, so a second feature
## asking for the same method would silently lose its hook. Features register a callback here
## instead of hooking it themselves.

type
  UpdateFn = proc(self: pointer, gameTime: pointer) {.cdecl, gcsafe.}
  TickCb* = proc(self: pointer) {.nimcall.}

var
  gHook: Hook
  gCallbacks: seq[TickCb] = @[]

proc onPanelTick*(cb: TickCb) =
  ## Callbacks run every frame the control panel updates, in registration order.
  gCallbacks.add cb

proc hookUpdate(self: pointer, gameTime: pointer) {.cdecl.} =
  let orig = origAs[UpdateFn](gHook)
  if orig != nil: orig(self, gameTime)
  if self == nil: return
  for cb in gCallbacks:
    guard "ControlPanel.Update":
      cb(self)

gHook = newHook(CONTROL_PANEL, "Update", 1, cast[pointer](hookUpdate))

proc installPanelUpdate*(): bool =
  ## Idempotent: the first feature to ask installs it, the rest reuse it.
  if gHook.installed: return true
  let cp = getClass(CONTROL_PANEL)
  if cp == nil:
    logE("panelupdate: ControlPanel class not found")
    return false
  if not gHook.install(cp):
    logE("panelupdate: ControlPanel::Update hook failed")
    return false
  true
