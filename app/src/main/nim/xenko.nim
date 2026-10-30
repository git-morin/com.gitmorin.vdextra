## Object layouts specific to Xenko, the engine Virtual Desktop is built on, read off the
## decompiled assemblies rather than guessed.
include nemohooks/features

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

const
  THICKNESS_BOTTOM* = 0
  THICKNESS_LEFT* = 1
  THICKNESS_RIGHT* = 2
  THICKNESS_TOP* = 3
