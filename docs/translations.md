# Adding a translation

A language is just a dictionary file named after its BCP-47 tag:

```
app/src/main/assets/dict/<tag>.json      e.g. zh.json, fr.json, pt-BR.json
```

Each file maps Virtual Desktop's own English UI string to its translation. Any string absent
from the file is left untouched, so a partial dictionary is perfectly valid:

```json
{
  "Unable to retrieve your computers": "无法获取您的电脑列表",
  "Connect": "连接"
}
```

Drop the file in and rebuild — it appears in the UI-language picker automatically. There is no
list to register it in and no code to change; the picker enumerates `assets/dict/` and takes
each language's display name from its tag. Adding `fr.json` also makes French the default on
French-language headsets, since an unset picker follows the system language.

## How a language is chosen

1. The language explicitly chosen in the picker, if there is one — including English, which is
   stored as "no dictionary" rather than as a reverse translation.
2. Otherwise the best bundled match for the system's languages, in the user's own order of
   preference: exact tag (`pt-BR`), then bare language (`pt`), then any region of that language
   (a `pt-PT` device still gets a bundled `pt-BR` dictionary).
3. Otherwise English, by applying no dictionary at all.

Because an explicit choice of English is stored as an empty tag rather than as an absent one, it
stays distinguishable from "never chosen" — which is what makes the system fallback stop
applying the moment the user picks anything.

## Fonts, before you add a non-Latin language

Virtual Desktop's own font is swapped for a full-coverage one only when a string contains a
codepoint above `U+2E7F` (`hasCjk` in [`app/src/main/nim/mono.nim`](../app/src/main/nim/mono.nim)).

- **Latin-script languages** render on the stock font and need nothing extra.
- **CJK and Hangul** sit above the threshold, so the swap fires. Whether the captured font
  covers kana or Hangul specifically is unverified.
- **Cyrillic and Greek** sit *below* it, so the swap never fires and the stock font probably
  lacks the glyphs — they would render as missing-glyph boxes. That check needs generalising
  from "codepoint above `U+2E7F`" to "the current font cannot render this string" first, which
  is answerable from the `CharacterToGlyph` map the font probing already reads.

## Translating the module's own UI

The strings for VDExtra's own screens are ordinary Android resources, separate from the
injected dictionaries: `app/src/main/res/values/strings.xml` for English and
`values-<lang>/strings.xml` for a translation. CI fails the build if a locale is missing a
string the default has.
