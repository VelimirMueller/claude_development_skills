#!/usr/bin/env bash
# Validate plugin structure: manifest, SKILL.md frontmatter, reference link resolution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
fail()  { red "FAIL: $1"; exit 1; }

# Required tools
command -v jq >/dev/null 2>&1 || fail "jq not installed (apt install jq, brew install jq)"

# 1. Manifest
MANIFEST=".claude-plugin/plugin.json"
[ -f "$MANIFEST" ] || fail "missing $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "$MANIFEST is not valid JSON"
for field in name version description author; do
  jq -e ".$field" "$MANIFEST" >/dev/null || fail "$MANIFEST missing field: $field"
done

# 2. Skill files
mapfile -t SKILLS < <(find skills -type f -name SKILL.md 2>/dev/null | sort)
[ "${#SKILLS[@]}" -gt 0 ] || fail "no SKILL.md files found under skills/"

for SKILL in "${SKILLS[@]}"; do
  # Frontmatter present (file starts with ---)
  head -n 1 "$SKILL" | grep -qx -- '---' || fail "$SKILL missing YAML frontmatter opener (---)"

  # Frontmatter has name and description
  FRONTMATTER=$(awk '/^---$/{c++; if(c==2) exit; next} c==1' "$SKILL")
  echo "$FRONTMATTER" | grep -Eq '^name:\s+\S' || fail "$SKILL missing frontmatter field: name"
  echo "$FRONTMATTER" | grep -Eq '^description:\s+Use when' || fail "$SKILL description must start with 'Use when'"

  # name in frontmatter matches folder name
  NAME=$(echo "$FRONTMATTER" | grep -E '^name:' | sed -E 's/^name:[[:space:]]+//')
  FOLDER=$(basename "$(dirname "$SKILL")")
  [ "$NAME" = "$FOLDER" ] || fail "$SKILL name '$NAME' does not match folder '$FOLDER'"
done

# 3. Reference link resolution (relative .md links)
for SKILL in "${SKILLS[@]}"; do
  DIR="$(dirname "$SKILL")"
  mapfile -t REFS < <(grep -Eo '\.{1,2}/[A-Za-z0-9_./-]+\.md' "$SKILL" | sort -u || true)
  for REF in "${REFS[@]}"; do
    TARGET="$DIR/$REF"
    [ -f "$TARGET" ] || fail "$SKILL references missing file: $REF (resolved to $TARGET)"
  done
done

green "OK: validator passed (${#SKILLS[@]} skills checked)"
