## The Nimony features every module here needs.
## Included rather than imported: {.feature.} is module-scoped.
when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "assumeSync".}
