#!/usr/bin/env python3
"""Checks the String Catalog: every key has non-empty en and zh-Hans values,
every key used in App/Sources exists, and lists keys that no source file mentions."""
import json, re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
catalog = json.loads((root / "App/Resources/Localizable.xcstrings").read_text())["strings"]
files = {p: p.read_text() for p in (root / "App/Sources").rglob("*.swift")}
sources = "\n".join(files.values())
# Lines that hold identifiers rather than UI text: SF Symbol names, defaults and Keychain keys, comments.
not_ui = re.compile(r'static let \w+ = "|@AppStorage\(|forKey:|^\s*///?|systemName:')
ui_lines = "\n".join(line for name, text in files.items() if name.name != "Icons.swift"
                     for line in text.splitlines() if not not_ui.search(line))

problems = 0
for key, entry in sorted(catalog.items()):
    locs = entry.get("localizations", {})
    for lang in ("en", "zh-Hans"):
        unit = locs.get(lang, {}).get("stringUnit", {})
        variations = locs.get(lang, {}).get("variations")
        if not unit.get("value") and not variations:
            print(f"missing {lang}: {key}"); problems += 1

# Keys look like "area.name" or "area.name.more"; skip format-only and verbatim strings.
used = set(re.findall(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+)"', ui_lines))
# Keys built at run time with a prefix, e.g. "tier.\(tier)".
dynamic = set(re.findall(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*\.)\\\(', sources))
ignore_used = re.compile(r"^(com|dev|org|net|io)\.|\.(json|md|sqlite|plist|app|png|pdf|csv)$")
for key in sorted(used):
    if key not in catalog and not ignore_used.search(key) and not any(key.startswith(p) for p in dynamic):
        print(f"not in catalog: {key}"); problems += 1

# Suffixes appended at run time, e.g. key + ".since".
suffixes = set(re.findall(r'\+ "(\.[A-Za-z0-9.]+)"', sources))
def referenced(key):
    if key in sources or any(key.startswith(p) for p in dynamic):
        return True
    return any(key.endswith(s) and key[: -len(s)] in sources for s in suffixes)
unused = [k for k in catalog if not referenced(k)]
for key in sorted(unused):
    print(f"unused: {key}"); problems += 1

print(f"{len(catalog)} keys, {problems} problems")
sys.exit(1 if problems else 0)
