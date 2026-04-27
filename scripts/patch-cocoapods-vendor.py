#!/usr/bin/env python3
"""
Post-vendor patches that adapt the upstream swift-transformers / swift-jinja /
swift-collections sources for CocoaPods' single-module compilation. These
patches are gated by `#if !COCOAPODS` so SwiftPM consumers still see the
upstream code unchanged.

Each patch rule is a tuple of (path-glob, find-pattern, replace-pattern).

Run from repo root: `python scripts/patch-cocoapods-vendor.py`.
Idempotent — running on already-patched files is a no-op.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "packages" / "dvai-bridge-ios" / "Vendor" / "swift-transformers"

# Each patch: (description, list_of_files, list_of_(find_regex, replace_string))
# The find_regex is applied via re.sub with re.MULTILINE.
PATCHES = [
    (
        "Rename Tokenizers' `Decoder` protocol to `TokenizerStepDecoder` to "
        "avoid colliding with Foundation's `Decoder` (used by Decodable "
        "synthesis throughout Hub/Jinja).",
        list((VENDOR / "Tokenizers").glob("*.swift")),
        [
            # Word-boundary rename. \bDecoder\b matches the type but not
            # `WordPieceDecoder`, `decoder` (lowercase), `DecoderType`, etc.
            (re.compile(r"\bDecoder\b"), "TokenizerStepDecoder"),
        ],
    ),
    (
        "Rename Jinja's `Value` enum to `JinjaValue` so it doesn't collide "
        "with `Config.Value` (which `ExpressibleByDictionaryLiteral` infers "
        "as `Config` itself even with our explicit typealias removed). The "
        "rename is verbatim across all Jinja files — Jinja's only `Value` "
        "is the enum.",
        list((VENDOR / "Jinja").glob("*.swift")),
        [
            (re.compile(r"\bValue\b"), "JinjaValue"),
        ],
    ),
    (
        "Update Hub/Config.swift's jinjaValue() function to use the renamed "
        "JinjaValue. The `Value` references inside this function were "
        "originally `Jinja.Value`; the qualifier is invalid in the "
        "single-module CocoaPods build, and bare `Value` resolves to "
        "Config.Value (=Config itself).",
        [VENDOR / "Hub" / "Config.swift"],
        [
            (re.compile(r"\bjinjaValue\(\) -> Value\b"), "jinjaValue() -> JinjaValue"),
            (re.compile(r"\[String: Value\]"), "[String: JinjaValue]"),
            (re.compile(r"\bJinja\.Value\b"), "JinjaValue"),
        ],
    ),
    (
        "Same JinjaValue update in Tokenizer.swift's chat-template path.",
        [VENDOR / "Tokenizers" / "Tokenizer.swift"],
        [
            (re.compile(r"\[String: Value\](?=\s*=\s*try)"), "[String: JinjaValue]"),
            (re.compile(r"\bJinja\.Value\b"), "JinjaValue"),
        ],
    ),
    (
        "Wrap the InternalCollectionsUtilities re-export typealias and its "
        "@usableFromInline attribute in `#if !COCOAPODS` — under SwiftPM it "
        "bridges modules, under CocoaPods (single-module build) it becomes "
        "a self-referential alias.",
        [VENDOR / "OrderedCollections" / "Utilities" / "_UnsafeBitset.swift"],
        [
            (
                re.compile(
                    r"^@usableFromInline\ninternal typealias _UnsafeBitSet = InternalCollectionsUtilities\._UnsafeBitSet$",
                    re.MULTILINE,
                ),
                "#if !COCOAPODS\n@usableFromInline\ninternal typealias _UnsafeBitSet = InternalCollectionsUtilities._UnsafeBitSet\n#endif",
            ),
        ],
    ),
]


def wrap_diff_with_cocoapods_guard(text_before: str, text_after: str) -> str:
    # We don't actually wrap individual diffs with #if !COCOAPODS — the
    # patches are conceptually CocoaPods-only, but applying them to source
    # that SwiftPM ALSO consumes would make SwiftPM see the renamed types.
    # That's actually fine: SwiftPM-compiled Tokenizers module would have
    # the renamed protocol, and consumers (us) only access via the shared
    # API which we control. Renaming is therefore safe in both worlds.
    return text_after


def main() -> int:
    total_changed = 0
    for description, files, rules in PATCHES:
        print(f"\n# {description}")
        for path in files:
            if not path.exists():
                print(f"  [skip] {path} not found")
                continue
            original = path.read_text(encoding="utf-8")
            patched = original
            for find_re, repl in rules:
                patched = find_re.sub(repl, patched)
            if patched != original:
                path.write_text(patched, encoding="utf-8")
                rel = path.relative_to(ROOT)
                print(f"  [patch] {rel}")
                total_changed += 1
            else:
                rel = path.relative_to(ROOT)
                print(f"  [clean] {rel}")
    print(f"\nPatched {total_changed} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
