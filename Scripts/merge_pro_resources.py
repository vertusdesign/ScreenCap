#!/usr/bin/env python3
"""Merge private Pro-only Localizable.strings into an assembled app bundle."""

from __future__ import annotations

import re
import shutil
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

    for private_file in sorted(private_root.glob("*.lproj/Localizable.strings")):
        language_dir = bundle_root / private_file.parent.name
        language_dir.mkdir(parents=True, exist_ok=True)
        destination = language_dir / "Localizable.strings"
        if not destination.exists():
            shutil.copy2(private_file, destination)
            continue

        existing = keys_in(destination)
        additions = [
            line
            for line in private_file.read_text(encoding="utf-8").splitlines()
            if (match := re.match(r'^"([^"]+)"\s*=', line)) and match.group(1) not in existing
        ]
        if additions:
            with destination.open("a", encoding="utf-8") as handle:
                handle.write("\n" + "\n".join(additions) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
