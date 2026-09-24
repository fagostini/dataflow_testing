#!/usr/bin/env python3
"""Extract and flatten project.dependencies from all submodule pyproject.toml files.

Outputs a space-separated oneliner of unique package names (with extras preserved,
version specifiers stripped).
"""

import re
from pathlib import Path


def parse_gitmodules(gitmodules_path: Path) -> list[Path]:
    """Return submodule path references from .gitmodules."""
    paths: list[Path] = []
    for line in gitmodules_path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("path = "):
            paths.append(Path(stripped.split(" ", 2)[2]))
    return paths


def strip_versions(dep: str) -> str:
    """Given 'pkg[extra]>=1.0,<2.0', return 'pkg[extra]'."""
    return re.split(r"\s*[><=!~@]", dep, maxsplit=1)[0]


def extract_deps(pyproject: Path) -> list[str]:
    """Extract the 'project.dependencies' list from a pyproject.toml.

    Returns an empty list if the file is not found or has no dependencies
    section.  Skips silently.
    """
    try:
        import tomllib  # Python >=3.11
    except ImportError:
        import tomli as tomllib  # fallback

    try:
        data = tomllib.loads(pyproject.read_text())
    except Exception:
        return []

    deps = data.get("project", {}).get("dependencies", [])
    return deps


def main() -> None:
    root = Path(__file__).resolve().parent
    sub_paths = parse_gitmodules(root / ".gitmodules")

    seen: set[str] = set()
    order: list[str] = []
    special_lines: list[str] = []

    for sp in sub_paths:
        toml_path = root / sp / "pyproject.toml"
        if not toml_path.is_file():
            continue

        raw_deps = extract_deps(toml_path)
        for dep in raw_deps:
            cleaned = strip_versions(dep).strip()

            # Special case: panzi_json_logic handled separately
            if cleaned == "panzi_json_logic":
                special_lines.append("The panzi-json-logic package needs to be added as a PyPI package: pixi add --pypi panzi-json-logic")
                continue

            # Normalize extras: altair[all] -> altair-all
            cleaned = cleaned.replace("[", "-").replace("]", "")

            if cleaned and cleaned not in seen:
                seen.add(cleaned)
                order.append(cleaned)

    print(" ".join(order))
    for line in special_lines:
        print(line)


if __name__ == "__main__":
    main()
