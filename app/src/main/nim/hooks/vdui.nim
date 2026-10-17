import std/strutils
import ../vdlog, ../mono, hook

## Stage one of the VDExtra settings section: it only reports. Building the panel needs the
## real member names of VD's settings tab and of this Xenko build's UI classes, and guessing
## them would mean calling into the runtime with addresses that are not what we think they
## are. So this walks the tab once and logs what stage two has to call.

const
  SETTINGS_TAB = "VirtualDesktop.Mobile.SettingsTab, VirtualDesktop.Mobile"
  UI_ELEMENT = "Xenko.UI.UIElement, Xenko.UI"
  STACK_PANEL = "Xenko.UI.Panels.StackPanel, Xenko.UI"
  TEXT_BLOCK = "Xenko.UI.Controls.TextBlock, Xenko.UI"
  SCROLL_VIEWER = "Xenko.UI.Controls.ScrollViewer, Xenko.UI"

  ## Method names worth printing out of a class that has hundreds.
  WANTED = ["panel", "page", "root", "child", "grid", "stack", "add",
            "create", "build", "init", "tab", "content"]

type
  Ctor1Fn = proc(self, a0: pointer) {.cdecl, gcsafe.}

  VdUiFeature* = ref object of Feature
    ctor0, ctor1: Hook
    tabClass: MonoClass
    walked: bool

var vdUiFeature* = VdUiFeature(name: "vdui")

proc interesting(name: string): bool =
  let l = toLowerAscii(name)
  for w in WANTED:
    if w in l: return true
  false

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
  probe(UI_ELEMENT, {"get_Parent": 0, "get_VisualChildren": 0, "get_Name": 0,
                     "set_Name": 1, "set_Visibility": 1, "set_Margin": 1})
  probe(STACK_PANEL, {".ctor": 0, "get_Children": 0, "set_Orientation": 1})
  probe(TEXT_BLOCK, {".ctor": 0, "set_Text": 1, "set_TextSize": 1, "set_WrapText": 1,
                     "set_Font": 1})
  probe(SCROLL_VIEWER, {".ctor": 0, "get_Content": 0, "set_Content": 1})
  logI("[UI] object_new=" & $(pObjectNew != nil) & " object_init=" &
       $(pRuntimeObjectInit != nil) & " type_is_ref=" & $(pTypeIsReference != nil))

## Runs after the constructor, so the fields it reads are already populated. Only
## instance reference fields are followed: anything else would be a float read as an address.
proc walkInstance(self: pointer) =
  if vdUiFeature.walked or self == nil: return
  let cls = vdUiFeature.tabClass
  if cls == nil or pClassGetField == nil: return
  vdUiFeature.walked = true

  logI("[UI] --- SettingsTab instance " & objClassName(self) & " ---")
  for name in fieldNames(cls):
    let f = pClassGetField(cls, name.cstring)
    if f == nil or not fieldIsInstanceRef(f): continue
    let v = fieldGetPtr(self, f)
    logI("[UI]   " & name & ": " & className(fieldDeclaredClass(f)) & " = " &
         (if v == nil: "nil" else: objClassName(v)))
  logI("[UI] --- end SettingsTab instance ---")

proc hookCtor0(self: pointer) {.cdecl.} =
  let orig = origAs[VoidFn](vdUiFeature.ctor0)
  if orig != nil: orig(self)
  guard "SettingsTab.ctor/0": walkInstance(self)

proc hookCtor1(self, a0: pointer) {.cdecl.} =
  let orig = origAs[Ctor1Fn](vdUiFeature.ctor1)
  if orig != nil: orig(self, a0)
  guard "SettingsTab.ctor/1": walkInstance(self)

vdUiFeature.ctor0 = newHook(SETTINGS_TAB, ".ctor", 0, cast[pointer](hookCtor0))
vdUiFeature.ctor1 = newHook(SETTINGS_TAB, ".ctor", 1, cast[pointer](hookCtor1))

method install*(f: VdUiFeature): bool =
  let cls = getClass(SETTINGS_TAB)
  if cls == nil: return false
  f.tabClass = cls

  reportClass(cls)
  probeXenko()

  if f.ctor0.install(cls): logI("[UI] hooked SettingsTab::.ctor/0")
  elif f.ctor1.install(cls): logI("[UI] hooked SettingsTab::.ctor/1")
  else: logI("[UI] no SettingsTab ctor to hook; tab was built before setup ran")
  true
