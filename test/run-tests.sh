#!/usr/bin/env bash
#
#   run-tests.sh - fixture-based tests for agentcheck
#
#   Why this exists: every bug fixed in agentcheck so far (patches 0002-0007)
#   was the same shape - a check that silently stopped firing on a real setup
#   (df wrapping, cron moved to sqlite, AGENTS.md left out of a file list,
#   config tracked in git counted as "no backup"). A silent no-op in a tool
#   whose whole job is catching silent no-ops is the worst failure it can have.
#
#   These tests build a throwaway fake HOME for each scenario, run agentcheck
#   against it, and assert the right finding fired (or stayed silent). They
#   cover the file-driven checks only - the ones that regressed. System-state
#   checks (crontab, systemctl, df, node) read the real host and are left alone.
#
#   Run:  bash test/run-tests.sh          from the agentcheck dir, or anywhere
#   Exit: 0 if every assertion passed, 1 otherwise.

set -uo pipefail

AC="$(cd "$(dirname "$0")/.." && pwd)/agentcheck"
[ -x "$AC" ] || { echo "cannot find executable agentcheck at $AC"; exit 2; }

PASS=0
FAIL=0
FAILED_NAMES=""

# make a fresh empty fake HOME, print its path
mkhome() { mktemp -d "${TMPDIR:-/tmp}/agentcheck-test.XXXXXX"; }

# run agentcheck with a given HOME, from inside that HOME so $PWD is neutral,
# capture combined output. always returns 0 (agentcheck exits 0 by design).
run() {
  local home="$1"
  ( cd "$home" && HOME="$home" "$AC" --plain --verbose 2>&1 )
}

# assert_has  <test name>  <output>  <substring that must appear>
assert_has() {
  local name="$1" out="$2" needle="$3"
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    PASS=$((PASS+1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES\n    - $name"
    printf '  FAIL  %s\n        expected to find: %s\n' "$name" "$needle"
  fi
}

# assert_absent  <test name>  <output>  <substring that must NOT appear>
assert_absent() {
  local name="$1" out="$2" needle="$3"
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES\n    - $name"
    printf '  FAIL  %s\n        did not expect: %s\n' "$name" "$needle"
  else
    PASS=$((PASS+1)); printf '  ok    %s\n' "$name"
  fi
}

# write a cron_jobs sqlite fixture: $1=db path, $2=sessionTarget, $3=enabled(1/0)
mk_cron_db() {
  python3 - "$1" "$2" "$3" <<'PY'
import sqlite3, json, sys, os
db, target, enabled = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(db), exist_ok=True)
con = sqlite3.connect(db)
con.execute("create table cron_jobs (job_json text)")
job = {"schedule": "*/5 * * * *", "prompt": "do a thing",
       "sessionTarget": target, "enabled": bool(int(enabled))}
con.execute("insert into cron_jobs values (?)", (json.dumps(job),))
con.commit(); con.close()
PY
}

echo "agentcheck test suite"
echo "====================="

# ---- Scenario A: no agent stack at all -------------------------------------
H="$(mkhome)"
OUT="$(run "$H")"
assert_has  "A/no-stack: reports nothing found"        "$OUT" "No agent stack found"
assert_absent "A/no-stack: does not run sections"      "$OUT" "1. MEMORY"
rm -rf "$H"

# ---- Scenario B: memory file past the 24KB truncation cliff ----------------
H="$(mkhome)"; mkdir -p "$H/.openclaw/workspace"
{ printf 'source of truth lives in postgres.\n'; head -c 25000 /dev/zero | tr '\0' 'x'; } \
  > "$H/.openclaw/workspace/AGENTS.md"
OUT="$(run "$H")"
assert_has  "B/oversize: fires truncation-cliff crit"  "$OUT" "past the truncation cliff"
rm -rf "$H"

# ---- Scenario C: memory file approaching the cliff (17-24KB) ---------------
H="$(mkhome)"; mkdir -p "$H/.openclaw/workspace"
{ printf 'source of truth lives in postgres.\n'; head -c 19000 /dev/zero | tr '\0' 'x'; } \
  > "$H/.openclaw/workspace/AGENTS.md"
OUT="$(run "$H")"
assert_has  "C/approaching: fires approaching warn"    "$OUT" "approaching the truncation cliff"
assert_absent "C/approaching: not the crit"            "$OUT" "past the truncation cliff"
rm -rf "$H"

# ---- Scenario D: safe memory file that points at a source of truth ---------
H="$(mkhome)"; mkdir -p "$H/.openclaw/workspace"
printf 'Source of truth is the postgres core tables. Query it, do not trust copies.\n' \
  > "$H/.openclaw/workspace/AGENTS.md"
OUT="$(run "$H")"
assert_has  "D/sot: credits source-of-truth pointer"   "$OUT" "points at a source of truth"
assert_absent "D/sot: no stores-facts warning"         "$OUT" "stores facts instead of pointing"
rm -rf "$H"

# ---- Scenario E: memory file that just stores facts, no SoT pointer --------
H="$(mkhome)"; mkdir -p "$H/.openclaw/workspace"
printf 'Project notes. Build the app. Ship the app. That is the plan.\n' \
  > "$H/.openclaw/workspace/AGENTS.md"
OUT="$(run "$H")"
assert_has  "E/no-sot: fires stores-facts warning"     "$OUT" "stores facts instead of pointing"
rm -rf "$H"

# ---- Scenario F: a stack exists but no memory file anywhere ----------------
H="$(mkhome)"; mkdir -p "$H/.openclaw/state"
OUT="$(run "$H")"
assert_has  "F/no-mem: fires no-durable-memory crit"   "$OUT" "No durable memory file anywhere"
rm -rf "$H"

# ---- Scenario G: world-readable credential file ----------------------------
H="$(mkhome)"; mkdir -p "$H/.openclaw"
printf '{ "api_key": "sk-abcdefghijklmnopqrstuvwxyz0123" }\n' > "$H/.mcp.json"
chmod 644 "$H/.mcp.json"
OUT="$(run "$H")"
assert_has  "G/leaky: fires world-readable crit"       "$OUT" "Credentials in a world-readable file"
chmod 600 "$H/.mcp.json"
OUT="$(run "$H")"
assert_has  "G/owner-only: credits 600 perms"          "$OUT" "owner-only"
assert_absent "G/owner-only: no world-readable crit"   "$OUT" "Credentials in a world-readable file"
rm -rf "$H"

# ---- Scenario H: config backed up via git (regression: patch 0006) ---------
H="$(mkhome)"; mkdir -p "$H/.openclaw"
printf '{ "model": "x" }\n' > "$H/.openclaw/openclaw.json"
( cd "$H/.openclaw" \
  && git init -q \
  && git config user.email t@t && git config user.name t \
  && git add openclaw.json && git commit -qm init ) >/dev/null 2>&1
OUT="$(run "$H")"
assert_has  "H/git-backup: counts git tracking as backup" "$OUT" "tracked in git"
assert_absent "H/git-backup: no false no-backup warn"     "$OUT" "No backup of your agent config"
rm -rf "$H"

# ---- Scenario I: config with no backup at all ------------------------------
H="$(mkhome)"; mkdir -p "$H/.openclaw"
printf '{ "model": "x" }\n' > "$H/.openclaw/openclaw.json"
OUT="$(run "$H")"
assert_has  "I/no-backup: fires no-backup warn"        "$OUT" "No backup of your agent config"
rm -rf "$H"

# ---- Scenario J: cron in sqlite, not isolated (regression: patch 0003) -----
H="$(mkhome)"; mkdir -p "$H/.openclaw"
mk_cron_db "$H/.openclaw/state/openclaw.sqlite" "main" 1
OUT="$(run "$H")"
assert_has  "J/cron-unsafe: fires isolation crit"      "$OUT" "not isolated from your live sessions"
rm -rf "$H"

# ---- Scenario K: cron in sqlite, isolated -> silent ------------------------
H="$(mkhome)"; mkdir -p "$H/.openclaw"
mk_cron_db "$H/.openclaw/state/openclaw.sqlite" "isolated" 1
OUT="$(run "$H")"
assert_has  "K/cron-safe: credits isolated jobs"       "$OUT" "no scheduled job is writing into a live session"
assert_absent "K/cron-safe: no isolation crit"         "$OUT" "not isolated from your live sessions"
rm -rf "$H"

# ---- Scenario L: disabled unsafe cron job must not fire (patch 0003 detail)-
H="$(mkhome)"; mkdir -p "$H/.openclaw"
mk_cron_db "$H/.openclaw/state/openclaw.sqlite" "main" 0
OUT="$(run "$H")"
assert_absent "L/cron-disabled: disabled job ignored"  "$OUT" "not isolated from your live sessions"
rm -rf "$H"

# ---- Scenario M: blanket wildcard in the permission allowlist --------------
H="$(mkhome)"; mkdir -p "$H/.claude"
printf '{ "permissions": { "allow": ["Bash(*)"] } }\n' > "$H/.claude/settings.json"
OUT="$(run "$H")"
assert_has  "M/wildcard: fires blanket-wildcard crit"  "$OUT" "Blanket wildcard in your permission allowlist"
rm -rf "$H"

# ---- Scenario N: approval gate written down -> credited --------------------
H="$(mkhome)"; mkdir -p "$H/.openclaw/workspace"
printf 'Rules: never publish or delete without my explicit approval. Ask first.\n' \
  > "$H/.openclaw/workspace/AGENTS.md"
OUT="$(run "$H")"
assert_has  "N/guard: credits written approval gate"   "$OUT" "approval gates written down"
assert_absent "N/guard: no missing-gate crit"          "$OUT" "No written approval gate anywhere"
rm -rf "$H"


# ---- Scenario O: Cursor-only .cursorrules must not fire no-memory crit --------
H="$(mkhome)"; mkdir -p "$H/.cursor"
printf 'Source of truth is the postgres core tables. Query it, do not trust copies.
' \n  > "$H/.cursorrules"
OUT="$(run "$H")"
assert_absent "O/cursor-rules: no false no-memory crit"  "$OUT" "No durable memory file anywhere"
assert_has    "O/cursor-rules: credits sot pointer"       "$OUT" "points at a source of truth"
rm -rf "$H"
# ---- Scenario P: Cursor new-format .cursor/rules/ dir must not fire crit ------
H="$(mkhome)"; mkdir -p "$H/.cursor/rules"
printf 'Source of truth is the postgres core tables.
' > "$H/.cursor/rules/main.mdc"
OUT="$(run "$H")"
assert_absent "P/cursor-rules-dir: no false no-memory crit" "$OUT" "No durable memory file anywhere"
rm -rf "$H"
echo "====================="
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed tests:%b\n' "$FAILED_NAMES"
  exit 1
fi
exit 0
