#!/usr/bin/env python3
"""Validate the public ScreenCap localization catalogs without network access."""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
L10N = ROOT / "Resources" / "l10n"
LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
PLACEHOLDER = re.compile(r"%[@d]")
# Translation services occasionally leave batch sentinels in a localized
# value. Keep the check broad enough to catch variants such as ``ZXXQ4ZX`` or
# ``ZQ4ZX`` rather than relying on one exact spelling.
ARTIFACT_PATTERN = re.compile(r"ZX|ZQ|XQ\d|ZZ(?:\s|$)|cu3X|�")
INTENTIONAL_EQUAL_KEYS = {
    "about.copyright", "about.tagline", "player.window.title",
    "player.export.format.mov", "player.export.format.mp4",
}


def unescape(value: str) -> str:
    return value.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")


def parse(path: Path) -> tuple[dict[str, str], list[int]]:
    values: dict[str, str] = {}
    malformed: list[int] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.startswith("/*"):
            continue
        match = LINE.match(raw)
        if not match:
            malformed.append(number)
            continue
        values[unescape(match.group(1))] = unescape(match.group(2))
    return values, malformed


def main() -> int:
    errors: list[str] = []
    source, malformed = parse(L10N / "en.lproj" / "Localizable.strings")
    if malformed:
        errors.append(f"en.lproj malformed lines {malformed[:8]}")
    if not source:
        errors.append("English catalog is empty")
    files = sorted(L10N.glob("*.lproj/Localizable.strings"))
    for path in files:
        locale = path.parent.name.removesuffix(".lproj")
        values, malformed = parse(path)
        if malformed:
            errors.append(f"{locale}: malformed lines {malformed[:8]}")
        missing = sorted(set(source) - set(values))
        extra = sorted(set(values) - set(source))
        if missing:
            errors.append(f"{locale}: missing keys {missing[:8]}")
        if extra:
            errors.append(f"{locale}: unexpected keys {extra[:8]}")
        for key, original in source.items():
            value = values.get(key, "")
            if not value:
                errors.append(f"{locale}: empty value for {key}")
            if (
                locale != "en"
                and key not in INTENTIONAL_EQUAL_KEYS
                and value == original
                and len(re.findall(r"[A-Za-z]{2,}", original)) >= 2
            ):
                errors.append(f"{locale}: untranslated English fallback for {key}")
            if Counter(PLACEHOLDER.findall(original)) != Counter(PLACEHOLDER.findall(value)):
                errors.append(f"{locale}: placeholder mismatch for {key}")
            if ARTIFACT_PATTERN.search(value):
                errors.append(f"{locale}: translation marker leaked into {key}")
    print(f"Validated {len(files)} locales against {len(source)} public keys.")
    if errors:
        print("Localization validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Key sets, placeholders and syntax are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
