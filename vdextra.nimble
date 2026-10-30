# Dependency metadata for both package managers: nimble resolves it for the Nim 2 build that
# CMake drives, pnak for the Nimony one. `make deps` runs both.

version       = "0.4.0"
author        = "git-morin"
description   = "Xposed module adding features to Virtual Desktop on Quest"
license       = "MIT"
srcDir        = "app/src/main/nim"
bin           = @["vdextra"]

requires "nim >= 2.0.0"
requires "https://github.com/git-morin/nemo-hooks >= 1.0.0"
