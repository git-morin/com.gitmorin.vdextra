## The translation table. Kotlin fills it over `vdDictPut` before the panel is built, keyed on
## the exact English string VD passes to TextBlock::set_Text.
##
## Raw interop; see the nimohooks module docs for why these two features are on.
when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "assumeSync".}

import std/tables
import nimohooks

var gDict: Table[string, string]

proc dictPut*(key, val: string) =
  gDict[key] = val

proc dictLen*(): int = gDict.len

proc translate*(text: MonoString): MonoString =
  ## The replacement string, or nil to leave the original alone - which is also the answer for
  ## anything implausibly long, since set_Text is on a hot path.
  if gDict.len == 0: return nil
  let len = monoStrLen(text)
  if len <= 0 or len > 2048: return nil
  let key = utf16ToUtf8(monoStrChars(text), len)
  let hit = gDict.getOrDefault(key, "")
  if hit.len == 0: default(MonoString) else: makeMono(hit)
