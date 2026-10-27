## Raw interop; see the nimohooks module docs for why these two features are on.
when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "assumeSync".}

import nimohooks
import loadcontent

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

gHook = newHook(CONTROL_PANEL, "Update", 1, asPointer(hookUpdate))

proc installPanelUpdate*(): bool =
  if gHook.installed: return true # Idempotency check
  let cp = getClass(CONTROL_PANEL)
  if cp == nil:
    logE("panelupdate: ControlPanel class not found")
    return false
  if not gHook.install(cp):
    logE("panelupdate: ControlPanel::Update hook failed")
    return false
  true
