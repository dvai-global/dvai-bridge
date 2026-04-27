#!/usr/bin/env python3
"""
Wraps `import <intra-pod-module>` lines with `#if !COCOAPODS` so they compile
under CocoaPods (which collapses the whole pod into one module called
`DVAIBridge`) while remaining real `import` statements under SwiftPM.

CocoaPods auto-defines the `COCOAPODS` Swift compilation condition for
every source file built as part of any pod target, so the same source
tree builds correctly under both ecosystems with no duplication.

Run from repo root: `python scripts/wrap-cocoapods-imports.py`
The script is idempotent — running it again on already-wrapped files is
a no-op (it skips lines whose previous line is already `#if !COCOAPODS`).
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent

# Modules that resolve cross-target under SwiftPM but become same-module
# (or non-existent) under CocoaPods.
INTRA_POD_MODULES = {
    "Hub",
    "Jinja",
    "OrderedCollections",
    "InternalCollectionsUtilities",
    "Tokenizers",
    "DVAILlamaCore",
    "DVAILlamaCoreObjC",
    "DVAIFoundationCore",
    "DVAICoreMLCore",
}

# Files we operate on. Two roots: vendored upstream + DVAI sources.
SCAN_ROOTS = [
    ROOT / "packages" / "dvai-bridge-ios" / "Vendor" / "swift-transformers",
    ROOT / "packages" / "dvai-bridge-ios" / "ios" / "Sources",
    ROOT / "packages" / "dvai-bridge-ios-llama-core" / "ios" / "Sources",
    ROOT / "packages" / "dvai-bridge-ios-foundation-core" / "ios" / "Sources",
]

# Matches: `import Hub`, `import struct Hub.Config`, `import class Foo.Bar`,
# optionally followed by a `//`-style trailing comment.
IMPORT_RE = re.compile(
    r"^import\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?([A-Za-z_][A-Za-z0-9_]*)(?:\.[A-Za-z_][A-Za-z0-9_]*)?\s*(?://.*)?\s*$"
)


def should_wrap(line: str) -> bool:
    m = IMPORT_RE.match(line.rstrip())
    if not m:
        return False
    return m.group(1) in INTRA_POD_MODULES


def wrap_file(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    out_lines: list[str] = []
    in_lines = text.splitlines(keepends=True)
    changed = False
    i = 0
    while i < len(in_lines):
        line = in_lines[i]
        if should_wrap(line):
            # Idempotency: if previous emitted line is `#if !COCOAPODS`, skip.
            if out_lines and out_lines[-1].rstrip() == "#if !COCOAPODS":
                out_lines.append(line)
                i += 1
                continue
            # Wrap this single import line.
            eol = "\n" if line.endswith("\n") else ""
            out_lines.append(f"#if !COCOAPODS{eol}")
            out_lines.append(line if line.endswith("\n") else line + "\n")
            out_lines.append(f"#endif{eol if eol else chr(10)}")
            changed = True
            i += 1
        else:
            out_lines.append(line)
            i += 1
    if changed:
        path.write_text("".join(out_lines), encoding="utf-8")
    return changed


def main() -> int:
    total = 0
    edited = 0
    for root in SCAN_ROOTS:
        if not root.exists():
            print(f"[skip] {root} does not exist", file=sys.stderr)
            continue
        for p in root.rglob("*.swift"):
            total += 1
            if wrap_file(p):
                edited += 1
                print(f"[wrap] {p.relative_to(ROOT)}")
    print(f"\nScanned {total} .swift files; wrapped imports in {edited} of them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
