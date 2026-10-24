# fxclip identity

Use **fxclip**, all lowercase, in product names, window titles, buttons, release
copy and documentation, including at the beginning of a sentence.

The icon is a **white link mark on blue**. Platform masks and padding can adapt
to the operating system; the mark and blue identity stay the same.

## Artwork source

`tools/make_icon.swift` is the canonical drawing for the white mark and blue
gradient. Run it from the repository root:

```sh
swift tools/make_icon.swift
python3 Windows/tools/make_icon.py
```

The Swift generator exports the macOS sizes, iOS master, full-background Telegram
avatar and transparent Android mark. `--exports-only` refreshes Telegram, Android
and iOS while keeping existing macOS PNGs. Windows packages those macOS PNGs into
an ICO; Linux packages them directly. Android uses the exported mark for its
adaptive, monochrome, shortcut and widget icons.

## Technical names

Existing names such as `FxClip.xcodeproj`, `FxEngine`, C# namespaces and Android
theme identifiers are technical contracts rather than the public product name.
Keep their real casing in build commands and paths. Bundle IDs, signing IDs,
update identities and settings locations must remain compatible.

Examples and release descriptions must stay generic: never publish an operator's
personal identity, private group names or IDs, credentials or machine paths.
