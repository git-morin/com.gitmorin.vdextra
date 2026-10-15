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

Drop the file in and rebuild, it should appear in the UI-language picker automatically. There is no
list to register it in and no code to change; the picker enumerates `assets/dict/` and takes
each language's display name from its tag.

If you are adding a new language, please take the time to also translate the strings for this module.
