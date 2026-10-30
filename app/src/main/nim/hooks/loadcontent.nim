include nemohooks/features

import nemohooks
import nemohooks/backends/mono

const CONTROL_PANEL* = "VirtualDesktop.Mobile.ControlPanel, VirtualDesktop.Mobile"

type
  VoidRetFn = proc(self: pointer) {.cdecl, gcsafe.}
  LoadedCb* = proc(self: pointer) {.nimcall.}

var
  gHook: Hook
  gCallbacks: seq[LoadedCb] = @[]

proc onLoadContent*(cb: LoadedCb) =
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
