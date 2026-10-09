#!/usr/bin/env bash
# Validate the marketplace: plugin entries + version sync, catalogue ownership, SKILL.md frontmatter, reference link resolution.
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

# 1. Marketplace manifest — one repo, several plugins, each owning catalogue dirs.
#    A root plugin.json must not exist: with the default strict mode its components
#    are appended to EVERY marketplace entry, so each plugin would load every catalogue.
MARKET=".claude-plugin/marketplace.json"
[ -f "$MARKET" ] || fail "missing $MARKET"
jq -e . "$MARKET" >/dev/null || fail "$MARKET is not valid JSON"
[ ! -f ".claude-plugin/plugin.json" ] || fail ".claude-plugin/plugin.json must not exist (it leaks its skills into every plugin entry)"
jq -e '.plugins | length > 0' "$MARKET" >/dev/null || fail "$MARKET lists no plugins"
for field in name version description skills; do
  jq -e --arg f "$field" 'all(.plugins[]; has($f))' "$MARKET" >/dev/null || fail "a plugin in $MARKET is missing field: $field"
done
[ "$(jq -r '[.plugins[].name] | length' "$MARKET")" = "$(jq -r '[.plugins[].name] | unique | length' "$MARKET")" ] \
  || fail "$MARKET has duplicate plugin names"

# 1b. One version everywhere: every plugin entry, marketplace metadata, CHANGELOG, README
VERSION=$(jq -r '.metadata.version' "$MARKET")
[ -n "$VERSION" ] && [ "$VERSION" != null ] || fail "$MARKET metadata.version missing"
BAD=$(jq -r --arg v "$VERSION" '.plugins[] | select(.version != $v) | "\(.name)@\(.version)"' "$MARKET")
[ -z "$BAD" ] || fail "plugin versions differ from metadata.version $VERSION: $BAD"
TOP_ENTRY=$(grep -m1 -Eo '^## \[[^]]+\]' CHANGELOG.md || true)
[ "$TOP_ENTRY" = "## [$VERSION]" ] || fail "CHANGELOG.md top entry is '$TOP_ENTRY', expected '## [$VERSION]'"
grep -q "^\*\*v$VERSION\.\*\*" README.md || fail "README.md Status does not say '**v$VERSION.**'"

# 1c. Every catalogue that holds skills belongs to exactly one plugin, and every listed dir exists
#     (Claude Code discovers <dir>/<name>/SKILL.md under each listed dir; an unlisted catalogue ships zero skills)
for CAT in $(find skills -mindepth 2 -maxdepth 3 -name SKILL.md | cut -d/ -f2 | sort -u); do
  OWNERS=$(jq -r --arg c "./skills/$CAT/" '[.plugins[] | select(.skills | index($c))] | length' "$MARKET")
  [ "$OWNERS" = 1 ] || fail "./skills/$CAT/ is listed by $OWNERS plugins in $MARKET (expected exactly 1)"
done
for DIR in $(jq -r '.plugins[].skills[]' "$MARKET"); do
  [ -d "$DIR" ] || fail "$MARKET lists $DIR, which does not exist"
done
jq -e '.plugins[].dependencies[]? | (type == "string") or (type == "object" and (.name | type == "string") and (.name | length > 0))' "$MARKET" >/dev/null \
  || fail "a dependency in $MARKET is neither a string nor an object with a non-empty name"
for DEP in $(jq -r '.plugins[].dependencies[]? | if type == "string" then . else .name end' "$MARKET" | sort -u); do
  jq -e --arg d "$DEP" '.plugins | any(.name == $d)' "$MARKET" >/dev/null || fail "dependency '$DEP' is not a plugin in $MARKET"
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
  # Every description sits in context on every turn; keep it a trigger, not a summary
  DESC=$(echo "$FRONTMATTER" | grep -E '^description:' | sed -E 's/^description:[[:space:]]+//')
  [ "${#DESC}" -le 300 ] || fail "$SKILL description is ${#DESC} chars (max 300)"
  # A plain (unquoted) YAML scalar may not contain ": " — the frontmatter would not parse
  case "$DESC" in \"*|\'*) ;; *": "*) fail "$SKILL description contains ': ' unquoted (invalid YAML; use ' - ' or quote it)" ;; esac

  # name in frontmatter matches folder name
  NAME=$(echo "$FRONTMATTER" | grep -E '^name:' | sed -E 's/^name:[[:space:]]+//')
  FOLDER=$(basename "$(dirname "$SKILL")")
  [ "$NAME" = "$FOLDER" ] || fail "$SKILL name '$NAME' does not match folder '$FOLDER'"
done

# Skill names are unique across catalogues (a user may enable every plugin at once)
DUPES=$(for S in "${SKILLS[@]}"; do basename "$(dirname "$S")"; done | sort | uniq -d)
[ -z "$DUPES" ] || fail "skill names used in more than one catalogue: $DUPES"

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
