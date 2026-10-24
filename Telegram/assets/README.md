# fxclip avatar

`bot-avatar.png` is the Telegram export of the shared blue fxclip icon.
The canonical drawing lives in `tools/make_icon.swift`, with the same white link
mark used for the app icons. Telegram gets a full background for its circular crop.

From the repository root, regenerate the Telegram, Android and iOS exports with:

```sh
swift tools/make_icon.swift --exports-only
```

Running without `--exports-only` also redraws the macOS icon sizes. Windows and
Linux package those macOS exports directly.
