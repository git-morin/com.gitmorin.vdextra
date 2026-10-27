## Object layouts specific to Xenko, the engine Virtual Desktop is built on, read off the
## decompiled assemblies rather than guessed.
##
## Raw interop; see the nemohooks module docs for why these two features are on.
when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "assumeSync".}

## Mono's collection and array layout: a List-like collection keeps its storage behind an
## items pointer, a managed array *is* the storage, and both report their length at the same
## offset - so only the element read differs between them.
const
  LIST_ITEMS* = 16
  LIST_SIZE* = 24
  ARRAY_DATA* = 32

proc childCount*(coll: pointer): int =
  if coll == nil: 0
  else: int(cast[ptr int32](cast[uint64](coll) + uint64(LIST_SIZE))[])

proc childAt*(coll: pointer, i: int): pointer =
  let items = cast[ptr pointer](cast[uint64](coll) + uint64(LIST_ITEMS))[]
  if items == nil: return nil
  cast[ptr pointer](cast[uint64](items) + uint64(ARRAY_DATA + i * 8))[]

proc arrayAt*(arr: pointer, i: int): pointer =
  if arr == nil: return nil
  cast[ptr pointer](cast[uint64](arr) + uint64(ARRAY_DATA + i * 8))[]

## Xenko's Thickness stores its edges in this order, which is NOT the CSS one. Read from
## metadata (Bottom@16 Left@20 Right@24 Top@28, minus the 16-byte header): assuming
## left/top/right/bottom silently edits the wrong edge and looks almost right.
const
  THICKNESS_BOTTOM* = 0
  THICKNESS_LEFT* = 1
  THICKNESS_RIGHT* = 2
  THICKNESS_TOP* = 3
