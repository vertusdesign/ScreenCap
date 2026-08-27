#!/usr/bin/env python3
"""Merge private Pro-only Localizable.strings into an assembled app bundle."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def keys_in(path: Path) -> set[str]:
    return set(re.findall(r'^"([^"]+)"\s*=', path.read_text(encoding="utf-8"), re.MULTILINE))


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: merge_pro_resources.py <bundle-l10n-dir> <private-l10n-dir>", file=sys.stderr)
        return 2

    bundle_root = Path(sys.argv[1]).resolve()
    private_root = Path(sys.argv[2]).resolve()
    if not private_root.is_dir():
        print(f"private Pro resources not found: {private_root}", file=sys.stderr)
        return 1

    private_files = sorted(private_root.glob("*.lproj/Localizable.strings"))
    if not private_files:
        return 0

    # Pro currently ships approved translations only for English. Use those
    # English values as an explicit fallback in every locale rather than
    # leaking raw localization keys when a user runs Pro in another language.
    # A future locale-specific Pro file automatically overrides the fallback.
    english_file = private_root / "en.lproj" / "Localizable.strings"
    fallback_lines = (
        english_file.read_text(encoding="utf-8").splitlines()
        if english_file.exists() else []
    )
    # The glob yields the .lproj directories themselves.  Using parent.name
    # here silently turned the bundle's `Resources` directory into a fake
    # locale and wrote Resources/Resources/Localizable.strings.  The locale is
    # the directory's own name (for example `de.lproj`).
    bundle_languages = {path.name for path in bundle_root.glob("*.lproj")}
    language_names = bundle_languages | {path.parent.name for path in private_files}

    for language_name in sorted(language_names):
        private_file = private_root / language_name / "Localizable.strings"
        source_lines = (
            private_file.read_text(encoding="utf-8").splitlines()
            if private_file.exists() else fallback_lines
        )
        language_dir = bundle_root / language_name
        language_dir.mkdir(parents=True, exist_ok=True)
        destination = language_dir / "Localizable.strings"
        if not destination.exists():
            destination.write_text("\n".join(source_lines) + "\n", encoding="utf-8")
            continue

        existing = keys_in(destination)
        additions = [
            line
            for line in source_lines
            if (match := re.match(r'^"([^"]+)"\s*=', line)) and match.group(1) not in existing
        ]
        if additions:
            with destination.open("a", encoding="utf-8") as handle:
                handle.write("\n" + "\n".join(additions) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
