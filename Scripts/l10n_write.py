"""Shared writer for Localizable.strings files."""
import os, sys, json, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORDER_FILE = ROOT / "Scripts" / "l10n_keys.json"

def escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def write(lang, table):
    keys = json.loads(ORDER_FILE.read_text())
    missing = [k for k in keys if k not in table]
    if missing:
        raise SystemExit(f"{lang}: missing {len(missing)} keys: {missing[:5]}")
    extra = [k for k in table if k not in keys]
    if extra:
        raise SystemExit(f"{lang}: unknown keys {extra}")

    out = ROOT / "Resources" / "l10n" / f"{lang}.lproj"
    out.mkdir(parents=True, exist_ok=True)
    lines = [f"/* {lang} — ScreenCap */"]
    section = None
    for key in keys:
        head = key.split(".")[0]
        if head != section:
            section = head
            lines.append("")
        lines.append(f'"{key}" = "{escape(table[key])}";')
    (out / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"  {lang}: {len(keys)} keys")
