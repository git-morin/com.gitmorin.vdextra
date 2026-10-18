import std/strutils
import ../vdlog, ../mono, hook

## Stage one of the VDExtra settings section: it only reports. Building the panel needs the
## real member names of VD's settings tab and of this Xenko build's UI classes, and guessing
## them would mean calling into the runtime with addresses that are not what we think they
## are. The geometry it prints also says whether widening a label is the right lever for an
## overflowing translation, or whether the clipping happens further up the tree.

const
  SETTINGS_TAB = "VirtualDesktop.Mobile.SettingsTab, VirtualDesktop.Mobile"
  UI_ELEMENT = "Xenko.UI.UIElement, Xenko.UI"
  PANEL = "Xenko.UI.Panels.Panel, Xenko.UI"
  STACK_PANEL = "Xenko.UI.Panels.StackPanel, Xenko.UI"
  TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"
  SCROLL_VIEWER = "Xenko.UI.Controls.ScrollViewer, Xenko.UI"

  ## Method names worth printing out of a class that has hundreds.
  WANTED = ["panel", "page", "root", "child", "grid", "stack", "add",
            "create", "build", "init", "tab", "content"]

  ## Fields whose geometry decides the lever: the labels that carry translated text.
  LABEL_PREFIX = "_tb"

type
  Show1Fn = proc(self, a0: pointer) {.cdecl, gcsafe.}
  Show2Fn = proc(self, a0, a1: pointer) {.cdecl, gcsafe.}
  GetF32Fn = proc(e: pointer): cfloat {.cdecl, gcsafe.}
  GetObjFn = proc(e: pointer): MonoObject {.cdecl, gcsafe.}

  VdUiFeature* = ref object of Feature
    show0, show1, show2: Hook
    tabClass: MonoClass
    getWidth, getMinWidth, getMaxWidth: GetF32Fn
    getParent: GetObjFn
    walked: bool

var vdUiFeature* = VdUiFeature(name: "vdui")

proc interesting(name: string): bool =
  let l = toLowerAscii(name)
  for w in WANTED:
    if w in l: return true
  false

proc f2(v: float32): string =
  if v != v: "auto" else: formatFloat(v, ffDecimal, 1)

proc reportClass(cls: MonoClass) =
  logI("[UI] SettingsTab = " & className(cls))

  let fields = fieldNames(cls)
  logI("[UI] " & $fields.len & " field(s): " & fields.join(", "))

  let methods = methodNames(cls)
  var hits: seq[string] = @[]
  var ctors = 0
  for m in methods:
    if m == ".ctor": inc ctors
    elif interesting(m) and m notin hits: hits.add m
  logI("[UI] " & $methods.len & " method(s), " & $ctors & " ctor(s)")
  logI("[UI] candidate anchors: " & (if hits.len == 0: "none" else: hits.join(", ")))

proc probe(qname: string, members: openArray[(string, int)]) =
  let cls = getClass(qname)
  if cls == nil:
    logI("[UI] " & qname & " NOT FOUND")
    return
  var have: seq[string] = @[]
  var miss: seq[string] = @[]
  for (m, argc) in members:
    if methodAddr(cls, m, argc) != nil: have.add m & "/" & $argc
    else: miss.add m & "/" & $argc
  logI("[UI] " & className(cls) & " has[" & have.join(" ") & "] missing[" & miss.join(" ") & "]")

proc probeXenko() =
  probe(UI_ELEMENT, {"get_Width": 0, "set_Width": 1, "get_MinimumWidth": 0,
                     "set_MinimumWidth": 1, "get_MaximumWidth": 0, "get_Parent": 0,
                     "get_VisualChildren": 0, "set_Margin": 1})
  probe(PANEL, {"get_Children": 0})
  probe(STACK_PANEL, {".ctor": 0, "set_Orientation": 1})
  probe(TEXT_BLOCK, {".ctor": 0, "set_Text": 1, "set_TextSize": 1, "set_WrapText": 1})
  probe(SCROLL_VIEWER, {".ctor": 0, "get_Content": 0, "set_Content": 1})
  logI("[UI] object_new=" & $(pObjectNew != nil) & " object_init=" &
       $(pRuntimeObjectInit != nil) & " type_is_ref=" & $(pTypeIsReference != nil))

proc resolveGeometry() =
  let ui = getClass(UI_ELEMENT)
  if ui == nil: return
  vdUiFeature.getWidth = cast[GetF32Fn](methodAddr(ui, "get_Width", 0))
  vdUiFeature.getMinWidth = cast[GetF32Fn](methodAddr(ui, "get_MinimumWidth", 0))
  vdUiFeature.getMaxWidth = cast[GetF32Fn](methodAddr(ui, "get_MaximumWidth", 0))
  vdUiFeature.getParent = cast[GetObjFn](methodAddr(ui, "get_Parent", 0))

## Only float properties are read here. RenderSize and friends return a Vector3 by value, and
## calling those through a raw pointer would mean hand-rolling the struct-return ABI.
proc dumpLabel(name: string, e: MonoObject) =
  let f = vdUiFeature
  var line = "[UI]   " & name & " " & objClassName(e)
  if f.getWidth != nil: line.add " w=" & f2(float32(f.getWidth(e)))
  if f.getMinWidth != nil: line.add " minw=" & f2(float32(f.getMinWidth(e)))
  if f.getMaxWidth != nil: line.add " maxw=" & f2(float32(f.getMaxWidth(e)))

  var chain: seq[string] = @[]
  if f.getParent != nil:
    var cur = e
    for _ in 0 ..< 6:
      cur = f.getParent(cur)
      if cur == nil: break
      chain.add objClassName(cur)
  line.add " parents=" & (if chain.len == 0: "none" else: chain.join(" < "))
  logI(line)

## Runs on the first control-panel show, so the fields it reads are populated and arranged.
## Only instance reference fields are followed: anything else would be a float read as an
## address.
proc walkInstance(self: pointer) =
  if vdUiFeature.walked or self == nil: return
  let cls = vdUiFeature.tabClass
  if cls == nil or pClassGetField == nil: return
  vdUiFeature.walked = true

  logI("[UI] --- SettingsTab instance " & objClassName(self) & " ---")
  var labels = 0
  for name in fieldNames(cls):
    let fld = pClassGetField(cls, name.cstring)
    if fld == nil or not fieldIsInstanceRef(fld): continue
    let v = fieldGetPtr(self, fld)
    if v == nil: continue
    if name.startsWith(LABEL_PREFIX):
      dumpLabel(name, v)
      inc labels
    else:
      logI("[UI]   " & name & ": " & className(fieldDeclaredClass(fld)) & " = " &
           objClassName(v))
  logI("[UI] --- end, " & $labels & " label(s) ---")

proc hookShow0(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](vdUiFeature.show0)
  if orig != nil: orig(self)
  guard "OnControlPanelShow/0": walkInstance(self)

proc hookShow1(self, a0: pointer) {.cdecl.} =
  let orig = origAs[Show1Fn](vdUiFeature.show1)
  if orig != nil: orig(self, a0)
  guard "OnControlPanelShow/1": walkInstance(self)

proc hookShow2(self, a0, a1: pointer) {.cdecl.} =
  let orig = origAs[Show2Fn](vdUiFeature.show2)
  if orig != nil: orig(self, a0, a1)
  guard "OnControlPanelShow/2": walkInstance(self)

vdUiFeature.show0 = newHook(SETTINGS_TAB, "OnControlPanelShow", 0, cast[pointer](hookShow0))
vdUiFeature.show1 = newHook(SETTINGS_TAB, "OnControlPanelShow", 1, cast[pointer](hookShow1))
vdUiFeature.show2 = newHook(SETTINGS_TAB, "OnControlPanelShow", 2, cast[pointer](hookShow2))

method install*(f: VdUiFeature): bool =
  let cls = getClass(SETTINGS_TAB)
  if cls == nil: return false
  f.tabClass = cls

  reportClass(cls)
  probeXenko()
  resolveGeometry()

  if f.show0.install(cls): logI("[UI] hooked SettingsTab::OnControlPanelShow/0")
  elif f.show1.install(cls): logI("[UI] hooked SettingsTab::OnControlPanelShow/1")
  elif f.show2.install(cls): logI("[UI] hooked SettingsTab::OnControlPanelShow/2")
  else: logI("[UI] OnControlPanelShow not hookable; no instance walk")
  true
