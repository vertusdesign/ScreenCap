# Contributing

Bug reports, ideas and patches are all welcome. This is a small project maintained in spare
time, so please be patient with response times.

## Reporting a bug

Include:

- macOS version and Mac model
- app version (menu → About ScreenCap)
- interface language, and your **keyboard layout** if a shortcut misbehaved
- how many displays you have, and their scale factors if they differ
- what you expected and what happened

Overlay bugs are often specific to the display arrangement and to which display the pointer
was on. Mention both.

If a shortcut does nothing, check Settings first: a shortcut already owned by another app is
marked with a warning triangle, because macOS gives it to whoever registered first.

## Proposing a change

Open an issue before a large pull request, so the design can be agreed before you spend the
time. Small fixes can go straight to a pull request.

Two things that will be asked of any change to the drawing code:

- **It must survive export.** The overlay and the saved PNG go through the same renderer on
  purpose. A change that looks right on screen but not in the file is a bug, and the reverse
  is worse.
- **It must be undoable.** Anything that mutates the annotation list or the selection pushes
  a history state.

## Development

```bash
swift build
SCREENCAP_STRINGS=Resources/l10n .build/debug/ScreenCap
```

The localised strings live outside the binary, so a plain `swift build` run needs
`SCREENCAP_STRINGS` pointed at them, otherwise the UI shows raw keys.

Useful while debugging:

| Flag | Effect |
|---|---|
| `SCREENCAP_DEBUG=1` | Traces overlay lifecycle and input to stderr |
| `--capture area\|repeat\|window\|fullscreen` | Captures immediately after launch |
| `--window about\|preferences` | Opens a panel after launch |
| `--selftest <dir>` | Runs the headless render and export checks |

Before opening a pull request:

```bash
swift build 2>&1 | grep warning    # should be empty
.build/debug/ScreenCap --selftest /tmp/screencap-check
```

For a build that keeps its Screen Recording grant across rebuilds, sign it with a local
certificate — `make install` picks one up from your keychain automatically if it is there.
Without it macOS invalidates the grant on every rebuild.

## Translations

Strings live in `Resources/l10n/<lang>.lproj/Localizable.strings`, one file per language,
all sharing the key order in `Scripts/l10n_keys.json`.

To correct an existing translation, edit its file. Nothing else is needed — English fills in
for any key a translation is missing, so a partial file degrades gracefully rather than
showing raw keys.

To add a language, add its `.lproj` folder, add the code to `AppLanguage` in
`Sources/ScreenCap/Support/L10n.swift` with its endonym, and list it in
`CFBundleLocalizations` in `Resources/Info.plist`.

Corrections from native speakers are especially welcome — the existing set was not reviewed
by one for every language.

## Code style

Match what is there. The house habits, briefly: comments explain *why* rather than what,
platform quirks get a sentence saying which quirk and what it costs, and names are spelled
out rather than abbreviated.

## Licence

Contributions are accepted under the [MIT Licence](LICENSE), the same terms as the rest of
the project.
