#!/usr/bin/env bash
# Lightweight heuristic scan for declarations with no reference anywhere else
# in the repo. Usage: scripts/find-unreferenced-declarations.sh
#
# This is a grep, not a real dead-code analyzer: it cannot see protocol
# witnesses, @objc/selector-only call sites, dynamic member lookup, or SPM/
# preview-only usage, so a flagged name still needs a human to confirm it
# before deleting anything. It only checks two declaration shapes, chosen to
# match what tidying passes have actually found abandoned in this codebase:
#   - top-level `struct`/`class`/`enum` types (declared at column 0)
#   - `static func`/`private static func` (any indentation)
# Instance methods and properties are deliberately excluded -- protocol
# conformance (`body`, `id`, delegate callbacks) makes a grep-based check on
# those almost entirely false positives.
#
# First proved out on 2026-08-22 against two confirmed-dead declarations,
# InsightsPlacesMap (a View struct with no construction site) and
# MonthlyInsights.definedCategory(for:) (a private static func with no call
# site) -- both removed by hand once this script's approach was verified to
# find them.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SEARCH_DIRS=(LifeLog LifeLogTests LifeLogUITests)

extract_type_name() {
  sed -E 's/^(struct|final class|class|enum) +([A-Za-z_][A-Za-z0-9_]*).*/\2/'
}

extract_func_name() {
  sed -E 's/^[[:space:]]*(private )?static func +([A-Za-z_][A-Za-z0-9_]*).*/\2/'
}

found_any=0

check_declarations() {
  local pattern="$1" extractor="$2"
  while IFS=: read -r file line decl; do
    local name
    name="$(echo "$decl" | "$extractor")"
    [[ -n "$name" && "$name" != "$decl" ]] || continue
    local refs
    refs="$(grep -rnw "$name" "${SEARCH_DIRS[@]}" --include='*.swift' \
      | grep -v -F "$file:$line:" | wc -l | tr -d ' ')"
    if [[ "$refs" -eq 0 ]]; then
      printf 'UNREFERENCED  %s:%s  %s\n' "$file" "$line" "$name"
      found_any=1
    fi
  done < <(grep -rnE "$pattern" LifeLog --include='*.swift')
}

check_declarations '^(struct|final class|class|enum) [A-Za-z_]' extract_type_name
check_declarations '^[[:space:]]+(private )?static func [A-Za-z_]' extract_func_name

if [[ "$found_any" -eq 0 ]]; then
  echo "No unreferenced declarations found (heuristic scan -- see script header for what it can't see)."
fi
