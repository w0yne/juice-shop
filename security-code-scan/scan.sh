#!/usr/bin/env bash
#
# security-code-scan/scan.sh
# Run Claude Code to perform an AI-powered security audit on the codebase.
#
# Usage:
#   ./security-code-scan/scan.sh                    # Full scan
#   ./security-code-scan/scan.sh --diff main         # Diff scan (vs branch)
#   ./security-code-scan/scan.sh --files "routes/search.ts routes/login.ts"
#
# Requirements:
#   - Claude Code CLI (`claude`) installed and authenticated
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_DIR="$SCRIPT_DIR/reports"
TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
REPORT_FILE="$REPORT_DIR/scan_${TIMESTAMP}.json"
RAW_FILE="$REPORT_DIR/.scan_raw_${TIMESTAMP}.json"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
SCAN_MODE="full"
DIFF_BASE=""
TARGET_FILES=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --diff)
      SCAN_MODE="diff"
      DIFF_BASE="${2:-main}"
      shift 2
      ;;
    --files)
      SCAN_MODE="files"
      TARGET_FILES="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--diff <branch>] [--files \"file1 file2\"]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"; exit 1
      ;;
  esac
done

mkdir -p "$REPORT_DIR"

echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   🔒 Claude Code Security Scanner        ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# Build the scope description
SCOPE=""
case "$SCAN_MODE" in
  full)
    SCOPE="Perform a FULL security audit of the codebase. Read all files in routes/, lib/, models/, data/, and server.ts."
    echo -e "${CYAN}Mode:${NC} Full codebase scan"
    ;;
  diff)
    CHANGED="$(cd "$PROJECT_ROOT" && git diff --name-only "$DIFF_BASE" -- '*.ts' '*.js' | grep -E '^(routes|lib|models|data|server\.ts|frontend/src)' || true)"
    if [[ -z "$CHANGED" ]]; then
      echo -e "${GREEN}✅ No security-relevant files changed vs ${DIFF_BASE}. Nothing to scan.${NC}"
      exit 0
    fi
    SCOPE="Perform a TARGETED security audit of ONLY these changed files (diff vs ${DIFF_BASE}):"$'\n'"${CHANGED}"$'\n\n'"Focus exclusively on the code in these files."
    echo -e "${CYAN}Mode:${NC} Diff scan vs ${DIFF_BASE}"
    echo "$CHANGED" | sed 's/^/  /'
    ;;
  files)
    SCOPE="Perform a TARGETED security audit of ONLY these files:"$'\n'"${TARGET_FILES}"$'\n\n'"Focus exclusively on the code in these files."
    echo -e "${CYAN}Mode:${NC} Targeted file scan"
    ;;
esac

echo ""
echo -e "${CYAN}Scanning...${NC} (this may take a few minutes)"

# Read the CLAUDE.md instructions
INSTRUCTIONS="$(cat "$SCRIPT_DIR/CLAUDE.md")"

# Build the full prompt — write to temp file to avoid shell escaping issues
PROMPT_FILE="$(mktemp)"
cat > "$PROMPT_FILE" <<PROMPT_EOF
${INSTRUCTIONS}

## Scan Scope for This Run

${SCOPE}

IMPORTANT: Write the final JSON report to the file path: ${REPORT_FILE}

Now perform the security scan. Read each target file carefully, analyze it for vulnerabilities, then write the JSON report file.
PROMPT_EOF

# Build Claude Code arguments
CLAUDE_ARGS=(--permission-mode bypassPermissions -p --output-format json --max-turns 30)
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  CLAUDE_ARGS+=(--model "$CLAUDE_MODEL")
  echo -e "${CYAN}Model:${NC} ${CLAUDE_MODEL}"
fi

# Run Claude Code
cd "$PROJECT_ROOT"
claude "${CLAUDE_ARGS[@]}" "$(cat "$PROMPT_FILE")" > "$RAW_FILE" 2>&1 || true
rm -f "$PROMPT_FILE"

# Check if Claude wrote the report file directly
if [[ -f "$REPORT_FILE" ]] && python3 -c "import json; json.load(open('$REPORT_FILE'))" 2>/dev/null; then
  echo -e "${GREEN}✅ Report written directly by Claude Code${NC}"
else
  # Try to extract JSON from raw output
  echo -e "${YELLOW}Extracting report from Claude output...${NC}"
  python3 "$SCRIPT_DIR/extract_report.py" "$RAW_FILE" "$REPORT_FILE"
fi

# Display results
if [[ -f "$REPORT_FILE" ]] && python3 -c "
import json, sys
data = json.load(open('$REPORT_FILE'))
assert 'findings' in data
" 2>/dev/null; then
  python3 -c "
import json
data = json.load(open('$REPORT_FILE'))
findings = data.get('findings', [])
total = len(findings)
by_sev = {}
for f in findings:
    s = f.get('severity', 'UNKNOWN')
    by_sev[s] = by_sev.get(s, 0) + 1

print()
print(f'  Total findings: {total}')
for sev, emoji in [('CRITICAL','🔴'), ('HIGH','🟠'), ('MEDIUM','🟡'), ('LOW','🟢')]:
    if by_sev.get(sev, 0) > 0:
        print(f'  {emoji} {sev}: {by_sev[sev]}')
print()
print(f'  📄 Report: $REPORT_FILE')
"
else
  echo -e "${YELLOW}⚠️  Could not parse structured findings.${NC}"
  echo -e "  Raw output: ${RAW_FILE}"
fi

# Cleanup
rm -f "$RAW_FILE"
echo ""
