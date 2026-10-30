include nemohooks/features

import nemohooks
import nemohooks/backends/mono
import loadcontent

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

gHook = newHook(CONTROL_PANEL, "Update", 1, asPointer(hookUpdate))

proc installPanelUpdate*(): bool =
  if gHook.installed: return true
  let cp = getClass(CONTROL_PANEL)
  if cp == nil:
    logE("panelupdate: ControlPanel class not found")
    return false
  if not gHook.install(cp):
    logE("panelupdate: ControlPanel::Update hook failed")
    return false
  true
