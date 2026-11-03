#!/usr/bin/env python3
"""Fail CI when a relative Markdown link points at a missing file.

Checks README.md, CONTRIBUTING.md, docs/**/*.md, and realtime/README.md.
Only relative links are verified; external URLs are left alone so this
check never flakes on network or provider status pages.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")

TARGETS = [
    ROOT / "README.md",
    ROOT / "CONTRIBUTING.md",
    ROOT / "realtime" / "README.md",
    *sorted((ROOT / "docs").glob("*.md")),
]


def failures() -> list[str]:
    problems: list[str] = []
    for doc in TARGETS:
        if not doc.is_file():
            problems.append(f"{doc.relative_to(ROOT)}: file is missing")
            continue
        for lineno, line in enumerate(doc.read_text().splitlines(), 1):
            for match in LINK.finditer(line):
                target = match.group(1)
                if (
                    not target
                    or target.startswith(("#", "mailto:"))
                    or "://" in target
                ):
                    continue
                path = target.split("#", 1)[0]
                if not path:
                    continue
                resolved = (doc.parent / path).resolve()
                try:
                    resolved.relative_to(ROOT)
                except ValueError:
                    problems.append(
                        f"{doc.relative_to(ROOT)}:{lineno}: "
                        f"link escapes the repo: {target}"
                    )
                    continue
                if not resolved.exists():
                    problems.append(
                        f"{doc.relative_to(ROOT)}:{lineno}: "
                        f"broken link: {target}"
                    )
    return problems


def main() -> int:
    problems = failures()
    if problems:
        print("\n".join(problems))
        return 1
    print(f"Checked {len(TARGETS)} docs, all relative links resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
