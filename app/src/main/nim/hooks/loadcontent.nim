include nemohooks/features

import nemohooks
import nemohooks/backends/mono

## Shared owner of ControlPanel.LoadContent.
##
## Several features need to run there - it is the only point before VD's single layout pass,
## which is what makes injected elements visible to its bounds and depth assignment. Dobby
## installs one hook per address, so the second feature to ask for the same method silently
## lost its hook. This owns it instead and fans out to whoever registered.

const CONTROL_PANEL* = "VirtualDesktop.Mobile.ControlPanel, VirtualDesktop.Mobile"

type
  VoidRetFn = proc(self: pointer) {.cdecl, gcsafe.}
  LoadedCb* = proc(self: pointer) {.nimcall.}

var
  gHook: Hook
  gCallbacks: seq[LoadedCb] = @[]

proc onLoadContent*(cb: LoadedCb) =
  ## Registered callbacks run after VD has built the panel, in registration order.
  gCallbacks.add cb

proc hookLoadContent(self: pointer) {.cdecl.} =
  let orig = origAs[VoidRetFn](gHook)
  if orig != nil: orig(self)
  if self == nil: return
  for cb in gCallbacks:
    guard "ControlPanel.LoadContent":
      cb(self)

gHook = newHook(CONTROL_PANEL, "LoadContent", 0, asPointer(hookLoadContent))

proc installLoadContent*(): bool =
  if gHook.installed: return true # Idempotency check
  let cp = getClass(CONTROL_PANEL)
  if cp == nil:
    logE("loadcontent: ControlPanel class not found")
    return false
  if not gHook.install(cp):
    logE("loadcontent: ControlPanel::LoadContent hook failed")
    return false
  true
