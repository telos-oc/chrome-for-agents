#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/../install-hermes.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

make_fake_bin_dir() {
  local bin_dir="$1"
  local uname_value="${2:-Linux}"
  mkdir -p "$bin_dir"

  cat >"$bin_dir/node" <<'EOF'
#!/usr/bin/env bash
echo "v20.19.0"
EOF

  cat >"$bin_dir/npx" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--version"* ]]; then
  echo "10.8.2"
  exit 0
fi
exit 0
EOF

  cat >"$bin_dir/hermes" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "Hermes Agent v0.test"
  exit 0
fi
if [[ "$1" == "gateway" && "${2:-}" == "restart" ]]; then
  echo "gateway restarted"
  exit 0
fi
exit 0
EOF

  cat >"$bin_dir/google-chrome" <<'EOF'
#!/usr/bin/env bash
echo "Google Chrome 144.0.0.0"
EOF

  cat >"$bin_dir/uname" <<EOF
#!/usr/bin/env bash
echo "$uname_value"
EOF

  chmod +x "$bin_dir"/*
}

run_installer() {
  local home_dir="$1"
  local config_path="$2"
  local bin_dir="$3"
  PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" HERMES_CONFIG_PATH="$config_path" bash "$INSTALLER" >/tmp/chrome-for-agents-test.log 2>&1
}

run_installer_expect_fail() {
  local home_dir="$1"
  local config_path="$2"
  local bin_dir="$3"
  set +e
  PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" HERMES_CONFIG_PATH="$config_path" bash "$INSTALLER" >/tmp/chrome-for-agents-test.log 2>&1
  local exit_code=$?
  set -e
  [[ $exit_code -ne 0 ]] || fail "Expected installer to fail"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "Expected '$needle' in $file"
}

assert_count() {
  local expected="$1"
  local file="$2"
  local needle="$3"
  local actual
  actual="$(grep -Fc -- "$needle" "$file")"
  [[ "$actual" == "$expected" ]] || fail "Expected $expected occurrences of '$needle' in $file, got $actual"
}

# Test 1: creates config from scratch
TEST1_HOME="$TMP_ROOT/home1"
TEST1_BIN="$TMP_ROOT/bin1"
TEST1_CONFIG="$TEST1_HOME/.hermes/config.yaml"
mkdir -p "$TEST1_HOME"
make_fake_bin_dir "$TEST1_BIN"
run_installer "$TEST1_HOME" "$TEST1_CONFIG" "$TEST1_BIN"
assert_contains "$TEST1_CONFIG" "mcp_servers:"
assert_contains "$TEST1_CONFIG" "  chrome-devtools:"
assert_contains "$TEST1_CONFIG" "      - --autoConnect"
pass "creates config from scratch"

# Test 2: appends entry into existing mcp_servers block
TEST2_HOME="$TMP_ROOT/home2"
TEST2_BIN="$TMP_ROOT/bin2"
TEST2_CONFIG="$TEST2_HOME/.hermes/config.yaml"
mkdir -p "$(dirname "$TEST2_CONFIG")"
make_fake_bin_dir "$TEST2_BIN"
cat >"$TEST2_CONFIG" <<'EOF'
model:
  default: test
mcp_servers:
  existing-server:
    command: existing
other_key:
  enabled: true
EOF
run_installer "$TEST2_HOME" "$TEST2_CONFIG" "$TEST2_BIN"
assert_contains "$TEST2_CONFIG" "  existing-server:"
assert_contains "$TEST2_CONFIG" "  chrome-devtools:"
assert_contains "$TEST2_CONFIG" "other_key:"
pass "adds chrome-devtools into existing mcp_servers block"

# Test 3: idempotent update
TEST3_HOME="$TMP_ROOT/home3"
TEST3_BIN="$TMP_ROOT/bin3"
TEST3_CONFIG="$TEST3_HOME/.hermes/config.yaml"
mkdir -p "$TEST3_HOME"
make_fake_bin_dir "$TEST3_BIN"
run_installer "$TEST3_HOME" "$TEST3_CONFIG" "$TEST3_BIN"
run_installer "$TEST3_HOME" "$TEST3_CONFIG" "$TEST3_BIN"
assert_count 1 "$TEST3_CONFIG" "  chrome-devtools:"
assert_count 1 "$TEST3_CONFIG" "      - --autoConnect"
pass "installer is idempotent"

# Test 4: handles inline mcp_servers map without duplicating top-level key
TEST4_HOME="$TMP_ROOT/home4"
TEST4_BIN="$TMP_ROOT/bin4"
TEST4_CONFIG="$TEST4_HOME/.hermes/config.yaml"
mkdir -p "$(dirname "$TEST4_CONFIG")"
make_fake_bin_dir "$TEST4_BIN"
cat >"$TEST4_CONFIG" <<'EOF'
model:
  default: test
mcp_servers: {} # placeholder
other_key:
  enabled: true
EOF
run_installer "$TEST4_HOME" "$TEST4_CONFIG" "$TEST4_BIN"
assert_count 1 "$TEST4_CONFIG" "mcp_servers:"
assert_contains "$TEST4_CONFIG" "  chrome-devtools:"
assert_contains "$TEST4_CONFIG" "other_key:"
pass "replaces inline mcp_servers map safely"

# Test 5: handles macOS Chrome app bundle path with spaces
TEST5_HOME="$TMP_ROOT/home5"
TEST5_BIN="$TMP_ROOT/bin5"
TEST5_CONFIG="$TEST5_HOME/.hermes/config.yaml"
mkdir -p "$TEST5_HOME"
make_fake_bin_dir "$TEST5_BIN" "Darwin"
rm -f "$TEST5_BIN/google-chrome"
MAC_CHROME="$TEST5_HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p "$(dirname "$MAC_CHROME")"
cat >"$MAC_CHROME" <<'EOF'
#!/usr/bin/env bash
echo "Google Chrome 144.0.0.0"
EOF
chmod +x "$MAC_CHROME"
run_installer "$TEST5_HOME" "$TEST5_CONFIG" "$TEST5_BIN"
assert_contains "$TEST5_CONFIG" "  chrome-devtools:"
pass "supports macOS Chrome app bundle paths with spaces"

# Test 6: fails safely on unsupported non-empty inline mcp_servers map
TEST6_HOME="$TMP_ROOT/home6"
TEST6_BIN="$TMP_ROOT/bin6"
TEST6_CONFIG="$TEST6_HOME/.hermes/config.yaml"
mkdir -p "$(dirname "$TEST6_CONFIG")"
make_fake_bin_dir "$TEST6_BIN"
cat >"$TEST6_CONFIG" <<'EOF'
mcp_servers: { existing-server: { command: existing } }
EOF
run_installer_expect_fail "$TEST6_HOME" "$TEST6_CONFIG" "$TEST6_BIN"
assert_contains /tmp/chrome-for-agents-test.log "Unsupported inline YAML for mcp_servers"
assert_count 1 "$TEST6_CONFIG" "mcp_servers:"
pass "fails safely on unsupported non-empty inline mcp_servers map"

printf '\nAll installer tests passed.\n'
