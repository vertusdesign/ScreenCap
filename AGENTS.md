# ScreenCap project rules

## Localization is release-critical

- Every user-facing string in ScreenCap 3 must go through `L10n.t`; do not add
  literal UI copy in Swift.
- Every supported locale must contain the complete English key set and a
  professional, context-appropriate translation. Missing keys, empty values,
  malformed `.strings` syntax, placeholder mismatches, leaked translation
  markers, and untranslated English prose are release blockers.
- English may remain identical only for explicit technical/brand identifiers
  (for example model names, codecs, file formats, standard resolution labels,
  keyboard symbols, and product names). Short UI labels are translation
  candidates too; do not use the runtime English fallback as a shortcut.
- Run both `make localization-check` and the Pro check below before a build or
  release:

  ```bash
  make localization-check
  make private-localization-check PRIVATE_DIR=../ScreenCap-Pro-Private
  ```

- Maintainer translation scripts are offline-at-runtime tooling only. Generated
  values require a human/native-speaker review before an App Store release.

## Public/Pro boundary

`ScreenCap-Pro-Private` is a separate private Git worktree. Keep Player source
and Pro localization catalogs there; never commit them to this public checkout.
The public build must remain Player-free, while the Pro build must validate all
private catalogs before staging them temporarily.
