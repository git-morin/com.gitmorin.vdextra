# Package metadata for pnak, Nimony's package manager. The module has no dependencies beyond
# the standard library; this exists so a future one is declared in the place pnak looks, and
# so `pnak pin` can lock the closure.

version       = "0.4.0"
author        = "git-morin"
description   = "Xposed module adding features to Virtual Desktop on Quest"
license       = "MIT"
srcDir        = "app/src/main/nim"
bin           = @["vdextra"]

requires "nim >= 2.0.0"
