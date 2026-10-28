# Dependency metadata for both package managers.
#
# TEMPORARY: nemohooks' repo is private, so neither manager can fetch it on a clean checkout
# and the library is vendored under vendor/nemohooks instead (see the Makefile header). The
# requires line below is the intended end state - restore it, drop the vendor copy and put the
# `nimble install -y --depsOnly` step back in CI once nemo-hooks is public.

version       = "0.4.0"
author        = "git-morin"
description   = "Xposed module adding features to Virtual Desktop on Quest"
license       = "MIT"
srcDir        = "app/src/main/nim"
bin           = @["vdextra"]

requires "nim >= 2.0.0"
# requires "https://github.com/git-morin/nemo-hooks >= 1.0.0"
