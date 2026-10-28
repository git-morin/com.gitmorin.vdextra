## nemohooks - write Xposed-style hooks in Nim.
##
## This module is the runtime-agnostic half: `Hook`, `Feature`, the registry and the poll. Add
## the backend the target runs - `nemohooks/backends/mono`, `backends/il2cpp` or
## `backends/native` - as a second import. Backends are not re-exported here because they share
## names on purpose, so a feature ports between runtimes by changing that one line.
##
## The logcat tag defaults to "nemohooks"; set `-d:nemohooksLogTag=YourTag` to change it.

import nemohooks/[compat, log, elfsyms, managed, backend, hook, feature, runtime]
export compat, log, elfsyms, managed, backend, hook, feature, runtime
