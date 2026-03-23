#!/usr/bin/env python3
"""Extract JSON security report from Claude Code raw output."""
import json
import re
import sys

def extract_report(raw_path, output_path):
    with open(raw_path, 'r') as f:
        raw = f.read()

    # Try 1: raw output is already valid JSON with findings
    try:
        data = json.loads(raw)
        if 'findings' in data:
            with open(output_path, 'w') as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
            return True
        # Claude --output-format json wraps in {"result": "..."}
        if 'result' in data:
            raw = data['result']
    except (json.JSONDecodeError, TypeError):
        pass

    # Try 2: find JSON block in text (possibly wrapped in markdown)
    # Look for the outermost { ... } containing "findings"
    patterns = [
        r'```json\s*(\{[\s\S]*?"findings"[\s\S]*?\})\s*```',
        r'(\{[\s\S]*?"findings"[\s\S]*\})',
    ]

    for pattern in patterns:
        matches = re.findall(pattern, raw)
        for match in matches:
            # Try to parse, trimming from the end if needed
            text = match.strip()
            # Find the balanced closing brace
            depth = 0
            end = -1
            for i, ch in enumerate(text):
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            if end > 0:
                text = text[:end + 1]

            try:
                data = json.loads(text)
                if 'findings' in data:
                    with open(output_path, 'w') as f:
                        json.dump(data, f, indent=2, ensure_ascii=False)
                    return True
            except json.JSONDecodeError:
                continue

    # Try 3: Claude wrote it as a file (check if output says it wrote to a path)
    print(f"Warning: Could not extract JSON report from {raw_path}", file=sys.stderr)
    # Save raw text as fallback
    with open(output_path, 'w') as f:
        f.write(raw)
    return False

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <raw_input> <json_output>", file=sys.stderr)
        sys.exit(1)
    success = extract_report(sys.argv[1], sys.argv[2])
    sys.exit(0 if success else 1)
