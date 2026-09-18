#!/usr/bin/env bash
# get_deps.sh - Extracts project.dependencies from all submodule pyproject.toml files
# Usage: ./get_deps.sh  or  make get-deps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── extract_deps() ──────────────────────────────────────────────
# Reads a pyproject.toml and prints each "project.dependencies" entry on its own line.
# Skips any submodule that has no pyproject.toml or has no dependencies section.
extract_deps() {
    local toml="$1"
    local in_project=0
    local in_deps=0
    local line_content

    while IFS= read -r line; do
        # Section header: [project]
        if [[ "$line" =~ ^\[project\]([[:space:]]#.*)?$ ]]; then
            in_project=1
            in_deps=0
            continue
        fi

        # Any other section header closes [project]
        if (( in_project )) && [[ "$line" =~ ^\[.+\] ]]; then
            in_project=0
            in_deps=0
            continue
        fi

        # dependencies = [...]  — could be single-line
        if (( in_project )) && [[ "$line" =~ ^dependencies[[:space:]]*= ]]; then
            if [[ "$line" == *"]"* ]]; then
                # single-line form: dependencies = ["a", "b"]
                while [[ "$line" =~ \"([^\"]+)\" ]]; do
                    echo "${BASH_REMATCH[1]}"
                    line="${line#*\"${BASH_REMATCH[1]}\"}"
                done
                return 0
            fi
            in_deps=1
            continue
        fi

        # Collect lines inside the dependencies block
        if (( in_deps )); then
            # Trailing-backslash skip (TOML continuation — rare but handle it)
            if [[ "$line" =~ ^[[:space:]]*\\ ]]; then
                continue
            fi

            # Close of array
            if [[ "$line" =~ ^[[:space:]]*\][[:space:]]*(#.*)?$ ]]; then
                in_deps=0
                continue
            fi

            # Pull out every quoted string on this line
            line_content="$line"
            while [[ "$line_content" =~ \"([^\"]+)\" ]]; do
                local val="${BASH_REMATCH[1]}"
                # Ignore stray brackets (e.g. continuation of optional-deps line)
                [[ "$val" =~ ^[\[\(] ]] && continue
                echo "$val"
                line_content="${line_content#*\"$val\"}"
            done
        fi
    done < "$toml"
}

# ── strip_versions() ────────────────────────────────────────────
# Given "package>=1.0,<2.0" or "pkg[extra]==1.4", drops everything after
# the package name (+ extras).  Whitespace is trimmed.
strip_versions() {
    echo "$1" | sed -E 's/[[:space:]]*(>=|==|<=|~=|!=|>|<|@)[^ ,;]*//g' | xargs
}

# ── main ────────────────────────────────────────────────────────
raw_deps=""

while IFS= read -r line; do
    module_path="$(echo "$line" | sed -n 's/^path = \(.*\)/\1/p')"
    [[ -z "$module_path" ]] && continue

    toml_file="$SCRIPT_DIR/$module_path/pyproject.toml"
    [[ -f "$toml_file" ]] || continue  # skip silently

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        cleaned="$(strip_versions "$dep")"
        [[ -n "$cleaned" ]] && raw_deps="$raw_deps $cleaned"
    done < <(extract_deps "$toml_file")
done < <(grep "^path = " "$SCRIPT_DIR/.gitmodules")

# Print unique, trimmed oneliner
echo "$raw_deps" | xargs -n1 | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//'
echo  # trailing newline
