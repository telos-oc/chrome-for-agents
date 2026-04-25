#!/usr/bin/env bash
set -euo pipefail

REQUIRED_NODE_MAJOR=20
REQUIRED_NODE_MINOR=19
REQUIRED_CHROME_MAJOR=144
HERMES_CONFIG_PATH="${HERMES_CONFIG_PATH:-$HOME/.hermes/config.yaml}"

log() {
  printf '[chrome-for-agents] %s\n' "$1"
}

fail() {
  printf '[chrome-for-agents] ERROR: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

version_ge() {
  python3 - "$1" "$2" <<'PY'
import sys

def parse(v: str):
    parts = []
    for piece in v.strip().split('.'):
        digits = ''.join(ch for ch in piece if ch.isdigit())
        parts.append(int(digits or 0))
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])

print(0 if parse(sys.argv[1]) >= parse(sys.argv[2]) else 1)
PY
}

check_node() {
  require_command node
  local raw version minimum
  raw="$(node --version)"
  version="${raw#v}"
  minimum="${REQUIRED_NODE_MAJOR}.${REQUIRED_NODE_MINOR}.0"
  if [[ "$(version_ge "$version" "$minimum")" != "0" ]]; then
    fail "Node.js ${minimum}+ required, found ${raw}"
  fi
  log "Node.js OK (${raw})"
}

find_chrome_binary() {
  local candidates=(
    "google-chrome"
    "google-chrome-stable"
    "chromium"
    "chromium-browser"
    "brave-browser"
    "microsoft-edge"
  )

  case "$(uname -s)" in
    Darwin)
      candidates+=(
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        "/Applications/Chromium.app/Contents/MacOS/Chromium"
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
      )
      ;;
  esac

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ "$candidate" == */* ]]; then
      [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    else
      if command -v "$candidate" >/dev/null 2>&1; then
        command -v "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

check_chrome() {
  local chrome_bin raw version major
  chrome_bin="$(find_chrome_binary || true)"
  [[ -n "$chrome_bin" ]] || fail "Could not find Chrome/Chromium/Brave/Edge binary. Install Chrome 144+ first."

  raw="$("$chrome_bin" --version 2>/dev/null || true)"
  [[ -n "$raw" ]] || fail "Found browser binary at $chrome_bin but could not read version"

  version="$(python3 -c 'import re, sys
text = sys.argv[1]
match = re.search(r"(\d+)\.(\d+)\.(\d+)\.(\d+)", text)
if not match:
    raise SystemExit(1)
print(".".join(match.groups()))' "$raw")" || fail "Could not parse browser version from: $raw"

  major="${version%%.*}"
  if (( major < REQUIRED_CHROME_MAJOR )); then
    fail "Chrome/Chromium 144+ required for --autoConnect, found ${version}"
  fi
  log "Browser OK (${raw})"
}

check_hermes() {
  require_command hermes
  log "Hermes OK ($(hermes --version | head -n 1))"
}

check_python() {
  require_command python3
  log "Python OK ($(python3 --version 2>&1))"
}

check_npx() {
  require_command npx
  log "npx OK ($(npx --version))"
}

write_config() {
  mkdir -p "$(dirname "$HERMES_CONFIG_PATH")"
  if [[ -f "$HERMES_CONFIG_PATH" ]]; then
    local backup_path
    backup_path="${HERMES_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$HERMES_CONFIG_PATH" "$backup_path"
    log "Backed up existing config to $backup_path"
  fi

  python3 - "$HERMES_CONFIG_PATH" <<'PY'
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1]).expanduser()
config_path.parent.mkdir(parents=True, exist_ok=True)

new_block = [
    'mcp_servers:',
    '  chrome-devtools:',
    '    command: npx',
    '    args:',
    '      - -y',
    '      - chrome-devtools-mcp@latest',
    '      - --autoConnect',
    '      - --no-usage-statistics',
    '    timeout: 120',
    '    connect_timeout: 60',
]
entry_block = new_block[1:]

def is_top_level_key(line: str) -> bool:
    return bool(re.match(r'^[^\s#][^:]*:\s*(?:#.*)?$', line))

def parse_key_line(line: str, key: str, indent: int):
    pattern = r'^' + (' ' * indent) + re.escape(key) + r':(?:\s*(.*?)\s*)?$'
    match = re.match(pattern, line)
    if not match:
        return None
    remainder = (match.group(1) or '').strip()
    if remainder.startswith('#'):
        remainder = ''
    if ' #' in remainder:
        remainder = remainder.split(' #', 1)[0].rstrip()
    return remainder

def find_top_level_block(lines, key):
    start = None
    for idx, line in enumerate(lines):
        remainder = parse_key_line(line, key, 0)
        if remainder is None:
            continue
        if remainder not in ('', '{}', '[]', 'null', '~'):
            raise SystemExit(
                f'Unsupported inline YAML for {key}: {line}\n'
                'Please convert it to block style before running this installer.'
            )
        start = idx
        break
    if start is None:
        return None, None
    end = len(lines)
    for idx in range(start + 1, len(lines)):
        line = lines[idx]
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if is_top_level_key(line):
            end = idx
            break
    return start, end

def find_child_block(lines, start, end, key):
    child_start = None
    for idx in range(start + 1, end):
        remainder = parse_key_line(lines[idx], key, 2)
        if remainder is None:
            continue
        if remainder not in ('', '{}', '[]', 'null', '~'):
            raise SystemExit(
                f'Unsupported inline YAML for {key}: {lines[idx]}\n'
                'Please convert it to block style before running this installer.'
            )
        child_start = idx
        break
    if child_start is None:
        return None, None
    child_end = end
    for idx in range(child_start + 1, end):
        line = lines[idx]
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if re.match(r'^  [^\s#][^:]*:\s*(?:#.*)?$', line):
            child_end = idx
            break
    return child_start, child_end

existing = config_path.read_text() if config_path.exists() else ''
lines = existing.splitlines()

start, end = find_top_level_block(lines, 'mcp_servers')
if start is None:
    if lines and lines[-1].strip():
        lines.append('')
    lines.extend(new_block)
else:
    lines[start] = 'mcp_servers:'
    child_start, child_end = find_child_block(lines, start, end, 'chrome-devtools')
    if child_start is None:
        insertion = entry_block[:]
        if end > start + 1 and lines[end - 1].strip():
            insertion = [''] + insertion
        lines[end:end] = insertion
    else:
        lines[child_start:child_end] = entry_block

updated = '\n'.join(lines).rstrip() + '\n'
config_path.write_text(updated)
PY

  log "Updated Hermes config at $HERMES_CONFIG_PATH"
}

verify_config() {
  python3 - "$HERMES_CONFIG_PATH" <<'PY'
from pathlib import Path
import re
import sys

lines = Path(sys.argv[1]).expanduser().read_text().splitlines()

def parse_key_line(line: str, key: str, indent: int):
    pattern = r'^' + (' ' * indent) + re.escape(key) + r':(?:\s*(.*?)\s*)?$'
    match = re.match(pattern, line)
    if not match:
        return None
    remainder = (match.group(1) or '').strip()
    if remainder.startswith('#'):
        remainder = ''
    if ' #' in remainder:
        remainder = remainder.split(' #', 1)[0].rstrip()
    return remainder

def find_top_level_block(lines, key):
    start = None
    for idx, line in enumerate(lines):
        remainder = parse_key_line(line, key, 0)
        if remainder is None:
            continue
        if remainder not in ('', '{}', '[]', 'null', '~'):
            raise SystemExit(f'Unsupported top-level {key} line: {line}')
        start = idx
        break
    if start is None:
        raise SystemExit(f'Missing top-level key: {key}')
    for idx in range(start + 1, len(lines)):
        line = lines[idx]
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if re.match(r'^[^\s#][^:]*:\s*(?:#.*)?$', line):
            return start, idx
    return start, len(lines)

def find_child_block(lines, start, end, key):
    child_start = None
    for idx in range(start + 1, end):
        remainder = parse_key_line(lines[idx], key, 2)
        if remainder is None:
            continue
        if remainder not in ('', '{}', '[]', 'null', '~'):
            raise SystemExit(f'Unsupported {key} line: {lines[idx]}')
        child_start = idx
        break
    if child_start is None:
        raise SystemExit(f'Missing {key} entry under mcp_servers')
    for idx in range(child_start + 1, end):
        line = lines[idx]
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if re.match(r'^  [^\s#][^:]*:\s*(?:#.*)?$', line):
            return child_start, idx
    return child_start, end

mcp_blocks = [idx for idx, line in enumerate(lines) if parse_key_line(line, 'mcp_servers', 0) is not None]
if len(mcp_blocks) != 1:
    raise SystemExit(f'Expected exactly one top-level mcp_servers block, found {len(mcp_blocks)}')

start, end = find_top_level_block(lines, 'mcp_servers')
child_start, child_end = find_child_block(lines, start, end, 'chrome-devtools')
required = {
    '  chrome-devtools:',
    '    command: npx',
    '    args:',
    '      - -y',
    '      - chrome-devtools-mcp@latest',
    '      - --autoConnect',
    '      - --no-usage-statistics',
    '    timeout: 120',
    '    connect_timeout: 60',
}
block_lines = set(lines[child_start:child_end])
missing = sorted(required - block_lines)
if missing:
    raise SystemExit('Missing required chrome-devtools config lines:\n' + '\n'.join(missing))
PY
  log "Config verification OK"
}

restart_gateway() {
  log "Restarting Hermes gateway..."
  hermes gateway restart
  log "Gateway restart OK"
}

verify_package_resolution() {
  log "Verifying chrome-devtools-mcp package resolution via npx..."
  npx -y chrome-devtools-mcp@latest --help >/dev/null
  log "npx package resolution OK"
}

print_next_steps() {
  cat <<EOF

[chrome-for-agents] Install complete.

Next steps:
1. Open Chrome and go to chrome://inspect/#remote-debugging
2. Enable "Discover network targets" if it is not already on
3. Keep at least one Chrome tab open
4. Ask Hermes to list browser tabs
5. When Chrome shows the consent prompt, click Allow

Public one-liner for this installer:
  curl -fsSL https://raw.githubusercontent.com/telos-oc/chrome-for-agents/main/install-hermes.sh | bash
EOF
}

main() {
  log "Checking prerequisites..."
  check_python
  check_node
  check_npx
  check_hermes
  check_chrome
  write_config
  verify_config
  verify_package_resolution
  restart_gateway
  print_next_steps
}

main "$@"
