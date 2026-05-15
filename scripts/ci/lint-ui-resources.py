#!/usr/bin/env python3
"""Lint UI-facing Swift files for localized text and theme-driven colors."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

TEXT_SCAN_ROOTS = (
    "TerminalApp/Soyeht/Onboarding",
    "TerminalApp/Soyeht/APNs",
    "TerminalApp/Soyeht/Home",
    "TerminalApp/SoyehtMac/Welcome",
    "TerminalApp/SoyehtMac/Continuity",
)

COLOR_SCAN_ROOTS = TEXT_SCAN_ROOTS + (
    "Packages/SoyehtCore/Sources/SoyehtCore",
)

COLOR_ALLOWLIST_PATHS = (
    "Packages/SoyehtCore/Sources/SoyehtCore/Theme/",
    "Packages/SoyehtCore/Sources/SoyehtCore/Terminal/",
    "Packages/SoyehtCore/Sources/SoyehtCore/Preferences/TerminalPreferences.swift",
    "Packages/SoyehtCore/Sources/SoyehtCore/ClawStore/ClawMockData.swift",
    "TerminalApp/Soyeht/SoyehtTheme.swift",
    "TerminalApp/SoyehtMac/MacTheme.swift",
    "TerminalApp/SoyehtMac/ClawStore/MacClawStoreTheme.swift",
    "TerminalApp/SoyehtMac/ThemeCatalogWindowController.swift",
    "TerminalApp/SoyehtMac/ThemeEditorWindowController.swift",
)

IGNORED_PATH_PARTS = (
    "/.build/",
    "/DerivedData/",
    "/__Snapshots__/",
    "/Tests/",
    "TerminalApp/SoyehtTests/",
    "TerminalApp/SoyehtMacTests/",
)

UI_STRING_CALL_RE = re.compile(
    r"\b(Text|Button|Label|Toggle|Picker|Section|NavigationLink|TextField|SecureField)\(\s*"
    r"\"((?:[^\"\\]|\\.)*)\"",
    re.MULTILINE,
)

COLOR_NAMES = r"(?:black|white|red|green|blue|yellow|orange|purple|pink|gray|brown|cyan|mint|indigo|teal)"

HARD_CODED_COLOR_RES = (
    re.compile(rf"\bColor\.{COLOR_NAMES}\b"),
    re.compile(rf"(?:\breturn\s+|[(:,=\[]\s*)\.{COLOR_NAMES}\b"),
    re.compile(r"\bColor\s*\(\s*(red|hue|white|cgColor|uiColor|nsColor)\s*:"),
    re.compile(r"\b(UIColor|NSColor)\s*\("),
    re.compile(r"#[0-9A-Fa-f]{6}\b"),
)

COLOR_CONTEXT_RE = re.compile(
    r"(foregroundColor|foregroundStyle|background|fill|stroke|tint|shadow|border|accentColor|LinearGradient|colors:|Color\.)"
)

CASE_LABEL_RE = re.compile(r"\bcase\s+[^:]+:")
TECHNICAL_LITERAL_RE = re.compile(r"^[0-9]+(?:\.[0-9]+)?[A-Za-z%]{1,4}$")
LOCALIZATION_KEY_RE = re.compile(r"^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$")


@dataclass(frozen=True)
class Violation:
    path: Path
    line_number: int
    message: str
    line: str

    def format(self) -> str:
        relative = self.path.relative_to(REPO_ROOT)
        return f"{relative}:{self.line_number}: {self.message}\n    {self.line.strip()}"


def swift_files_under(roots: tuple[str, ...]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        root_path = REPO_ROOT / root
        if root_path.is_file() and root_path.suffix == ".swift":
            files.append(root_path)
        elif root_path.exists():
            files.extend(root_path.rglob("*.swift"))
    return sorted(set(files))


def should_ignore(path: Path) -> bool:
    normalized = path.relative_to(REPO_ROOT).as_posix()
    wrapped = f"/{normalized}"
    return any(part in wrapped or normalized.startswith(part) for part in IGNORED_PATH_PARTS)


def color_allowed_in(path: Path) -> bool:
    normalized = path.relative_to(REPO_ROOT).as_posix()
    return any(normalized.startswith(prefix) or normalized == prefix for prefix in COLOR_ALLOWLIST_PATHS)


def strip_swift_comments_preserving_positions(source: str) -> str:
    chars = list(source)
    index = 0
    in_string = False
    escaped = False
    block_comment_depth = 0

    while index < len(chars):
        char = chars[index]
        next_char = chars[index + 1] if index + 1 < len(chars) else ""

        if block_comment_depth:
            if char == "/" and next_char == "*":
                chars[index] = " "
                chars[index + 1] = " "
                block_comment_depth += 1
                index += 2
            elif char == "*" and next_char == "/":
                chars[index] = " "
                chars[index + 1] = " "
                block_comment_depth -= 1
                index += 2
            else:
                if char != "\n":
                    chars[index] = " "
                index += 1
            continue

        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if char == '"':
            in_string = True
            index += 1
            continue

        if char == "/" and next_char == "/":
            while index < len(chars) and chars[index] != "\n":
                chars[index] = " "
                index += 1
            continue

        if char == "/" and next_char == "*":
            chars[index] = " "
            chars[index + 1] = " "
            block_comment_depth = 1
            index += 2
            continue

        index += 1

    return "".join(chars)


def strip_swift_strings_preserving_positions(source: str) -> str:
    chars = list(source)
    index = 0
    in_string = False
    escaped = False

    while index < len(chars):
        char = chars[index]

        if in_string:
            if char != "\n":
                chars[index] = " "
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if char == '"':
            chars[index] = " "
            in_string = True

        index += 1

    return "".join(chars)


def source_line_at(source: str, position: int) -> str:
    start = source.rfind("\n", 0, position) + 1
    end = source.find("\n", position)
    if end == -1:
        end = len(source)
    return source[start:end]


def is_localization_key(value: str) -> bool:
    return bool(LOCALIZATION_KEY_RE.match(value))


def is_technical_literal(value: str) -> bool:
    stripped = value.strip()
    if not stripped:
        return True
    if stripped.startswith("system.") or stripped.startswith("sf."):
        return True
    if "\\(" in stripped:
        return True
    if TECHNICAL_LITERAL_RE.match(stripped):
        return True
    return False


def looks_like_visible_text(value: str) -> bool:
    if is_localization_key(value) or is_technical_literal(value):
        return False
    return any(ch.isalpha() for ch in value)


def lint_text_file(path: Path) -> list[Violation]:
    violations: list[Violation] = []
    source = path.read_text(encoding="utf-8")
    source_without_comments = strip_swift_comments_preserving_positions(source)

    for match in UI_STRING_CALL_RE.finditer(source_without_comments):
        value = match.group(2)
        if looks_like_visible_text(value):
            line_number = source.count("\n", 0, match.start(2)) + 1
            violations.append(
                Violation(
                    path,
                    line_number,
                    "visible UI text should use LocalizedStringResource/LocalizedStringKey or a string-catalog key",
                    source_line_at(source, match.start(2)),
                )
            )
    return violations


def lint_color_file(path: Path) -> list[Violation]:
    if color_allowed_in(path):
        return []

    violations: list[Violation] = []
    source = path.read_text(encoding="utf-8")
    source_without_comments = strip_swift_comments_preserving_positions(source)
    source_code_only = strip_swift_strings_preserving_positions(source_without_comments)
    original_lines = source.splitlines()
    code_lines = source_code_only.splitlines()

    for line_number, code_line in enumerate(code_lines, start=1):
        if "Color.clear" in code_line or ".clear" in code_line:
            line_without_clear = code_line.replace("Color.clear", "").replace(".clear", "")
        else:
            line_without_clear = code_line

        line_without_clear = CASE_LABEL_RE.sub("case:", line_without_clear)

        if not COLOR_CONTEXT_RE.search(line_without_clear):
            continue

        if any(pattern.search(line_without_clear) for pattern in HARD_CODED_COLOR_RES):
            violations.append(
                Violation(
                    path,
                    line_number,
                    "hardcoded UI color should use BrandColors, SoyehtTheme, MacTheme, or a dedicated theme token",
                    original_lines[line_number - 1],
                )
            )
    return violations


def main() -> int:
    violations: list[Violation] = []

    for path in swift_files_under(TEXT_SCAN_ROOTS):
        if not should_ignore(path):
            violations.extend(lint_text_file(path))

    for path in swift_files_under(COLOR_SCAN_ROOTS):
        if not should_ignore(path):
            violations.extend(lint_color_file(path))

    if violations:
        print("ui-resource-lint: FAIL\n")
        for violation in violations:
            print(violation.format())
        print("\nFix: localize visible UI strings and route UI colors through theme tokens.")
        return 1

    print("ui-resource-lint: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
