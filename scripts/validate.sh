#!/usr/bin/env bash
# Validate plugin structure: manifests + version sync, SKILL.md frontmatter, reference link resolution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Bash 4.0+ required (mapfile is a 4.0 builtin; macOS ships system bash 3.2)
[ "${BASH_VERSINFO[0]}" -ge 4 ] || {
  echo "FAIL: Bash 4.0+ required (macOS: brew install bash, then run via /opt/homebrew/bin/bash)" >&2
  exit 1
}

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

# 1b. Marketplace manifest + one version everywhere
MARKET=".claude-plugin/marketplace.json"
[ -f "$MARKET" ] || fail "missing $MARKET"
jq -e . "$MARKET" >/dev/null || fail "$MARKET is not valid JSON"
VERSION=$(jq -r .version "$MANIFEST")
PLUGIN_NAME=$(jq -r .name "$MANIFEST")
MARKET_VERSION=$(jq -r --arg n "$PLUGIN_NAME" '.plugins[] | select(.name == $n) | .version' "$MARKET")
[ -n "$MARKET_VERSION" ] && [ "$MARKET_VERSION" != null ] || fail "$MARKET does not list plugin '$PLUGIN_NAME' with a version"
[ "$MARKET_VERSION" = "$VERSION" ] || fail "$MARKET lists $PLUGIN_NAME at '$MARKET_VERSION', $MANIFEST says '$VERSION'"
TOP_ENTRY=$(grep -m1 -Eo '^## \[[^]]+\]' CHANGELOG.md || true)
[ "$TOP_ENTRY" = "## [$VERSION]" ] || fail "CHANGELOG.md top entry is '$TOP_ENTRY', expected '## [$VERSION]'"
grep -q "^\*\*v$VERSION\.\*\*" README.md || fail "README.md Status does not say '**v$VERSION.**'"

# 1c. Every catalogue that holds skills is registered in plugin.json "skills"
#     (Claude Code only discovers skills/<name>/SKILL.md one level deep by default;
#      catalogues sit one level deeper, so an unregistered one ships zero skills)
for CAT in $(find skills -mindepth 2 -maxdepth 3 -name SKILL.md | cut -d/ -f2 | sort -u); do
  jq -e --arg c "./skills/$CAT/" '.skills | index($c)' "$MANIFEST" >/dev/null \
    || fail "$MANIFEST \"skills\" does not list ./skills/$CAT/ (its skills would not load)"
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

# 3. Reference link resolution (relative .md links in every Markdown file under skills/)
mapfile -t DOCS < <(find skills -type f -name '*.md' | sort)
for DOC in "${DOCS[@]}"; do
  DIR="$(dirname "$DOC")"
  mapfile -t REFS < <(grep -Eo '\.{1,2}/[A-Za-z0-9_./-]+\.md' "$DOC" | sort -u || true)
  for REF in "${REFS[@]}"; do
    TARGET="$DIR/$REF"
    [ -f "$TARGET" ] || fail "$DOC references missing file: $REF (resolved to $TARGET)"
  done
done

green "OK: validator passed (v$VERSION, ${#SKILLS[@]} skills, ${#DOCS[@]} docs checked)"
