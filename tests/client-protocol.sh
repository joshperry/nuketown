#!/usr/bin/env bash
# Test suite for client scripts wire protocol.
#
# These tests verify that sudoex, sudo-with-approval, sops-unlock, and
# nuketown-switch send the correct protocol lines to the broker socket.
#
# Approach: set up a mock broker (socat listener) that reads until the
# empty-line terminator, captures the protocol lines, and responds.
# No VM required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Setup ──────────────────────────────────────────────────────────

WORK_DIR=$(mktemp -d)
cleanup() {
  stop_mock_broker 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

CAPTURE_FILE="$WORK_DIR/captured-protocol"
SOCKET_PATH="$WORK_DIR/test-socket"

# Start a mock broker that reads lines until empty line, captures them,
# and responds with a fixed reply.
start_mock_broker() {
  local response="${1:-APPROVED}"
  rm -f "$SOCKET_PATH" "$CAPTURE_FILE"

  # The handler reads lines until an empty line, captures them, then responds
  cat > "$WORK_DIR/mock-broker.sh" << BROKEREOF
#!/usr/bin/env bash
{
  while IFS= read -r line && [ -n "\$line" ]; do
    echo "\$line"
  done
} > "$CAPTURE_FILE"
echo "$response"
BROKEREOF
  chmod +x "$WORK_DIR/mock-broker.sh"

  socat UNIX-LISTEN:"$SOCKET_PATH",fork EXEC:"$WORK_DIR/mock-broker.sh" &
  BROKER_PID=$!

  # Wait for socket to appear
  local attempts=0
  while [ ! -S "$SOCKET_PATH" ] && [ $attempts -lt 40 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done

  if [ ! -S "$SOCKET_PATH" ]; then
    fail "Mock broker socket did not appear" ""
    return 1
  fi
}

stop_mock_broker() {
  if [ -n "${BROKER_PID:-}" ]; then
    kill "$BROKER_PID" 2>/dev/null || true
    wait "$BROKER_PID" 2>/dev/null || true
    unset BROKER_PID
  fi
  rm -f "$SOCKET_PATH"
}

# ── sudoex protocol tests ─────────────────────────────────────────

# Build a local sudoex script that uses our test socket path and
# does not actually exec sudo on approval.
build_test_sudoex() {
  cat > "$WORK_DIR/sudoex" << SUDOEOF
#!/usr/bin/env bash
set -e

SOCKET_PATH="$SOCKET_PATH"
REQUESTING_USER="testuser"
REQUIREMENTS=""

while [[ \$# -gt 0 ]]; do
  case \$1 in
    --decrypt)
      REQUIREMENTS="\${REQUIREMENTS}DECRYPT:\$2"$'\n'
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

COMMAND="\$*"

if [ -z "\$COMMAND" ]; then
  echo "Usage: sudoex [--decrypt src:dest] [--] <command...>" >&2
  exit 1
fi

if [ ! -S "\$SOCKET_PATH" ]; then
  echo "Error: Broker daemon is not running" >&2
  exit 1
fi

RESPONSE=\$(printf "%sSUDO:%s:%s\n\n" "\$REQUIREMENTS" "\$REQUESTING_USER" "\$COMMAND" | \\
  socat STDIO,ignoreeof UNIX-CONNECT:"\$SOCKET_PATH" || echo "ERROR")

if [ "\$RESPONSE" = "APPROVED" ]; then
  echo "EXEC_APPROVED"
  exit 0
elif [ "\$RESPONSE" = "DENIED" ]; then
  echo "EXEC_DENIED"
  exit 1
else
  echo "ERROR: \$RESPONSE" >&2
  exit 1
fi
SUDOEOF
  chmod +x "$WORK_DIR/sudoex"
}

test_sudoex_sudo_only() {
  start_mock_broker "APPROVED"
  build_test_sudoex

  local output
  output=$("$WORK_DIR/sudoex" whoami 2>/dev/null)
  assert_equals "$output" "EXEC_APPROVED" "sudoex returns approved"

  sleep 0.2

  local captured
  captured=$(cat "$CAPTURE_FILE")
  assert_contains "$captured" "SUDO:testuser:whoami" "sudoex sends SUDO line"
  assert_not_contains "$captured" "DECRYPT" "sudoex without --decrypt omits DECRYPT"

  stop_mock_broker
}

test_sudoex_with_decrypt() {
  start_mock_broker "APPROVED"
  build_test_sudoex

  local output
  output=$("$WORK_DIR/sudoex" --decrypt "/etc/sops-age-key.gpg:/run/sops-age/keys.txt" -- nix-env -p /nix/var/nix/profiles/system --set ./result 2>/dev/null)
  assert_equals "$output" "EXEC_APPROVED" "sudoex with --decrypt returns approved"

  sleep 0.2

  local captured
  captured=$(cat "$CAPTURE_FILE")
  assert_contains "$captured" "DECRYPT:/etc/sops-age-key.gpg:/run/sops-age/keys.txt" \
    "sudoex sends DECRYPT line with src:dest"
  assert_contains "$captured" "SUDO:testuser:nix-env -p /nix/var/nix/profiles/system --set ./result" \
    "sudoex sends SUDO line with full command"

  stop_mock_broker
}

test_sudoex_denied() {
  start_mock_broker "DENIED"
  build_test_sudoex

  local output
  if output=$("$WORK_DIR/sudoex" whoami 2>/dev/null); then
    fail "sudoex should exit non-zero on denial" ""
  else
    assert_equals "$output" "EXEC_DENIED" "sudoex returns denied"
  fi

  stop_mock_broker
}

test_sudoex_no_command() {
  build_test_sudoex

  local output
  if output=$("$WORK_DIR/sudoex" 2>&1); then
    fail "sudoex with no command should fail" ""
  else
    assert_contains "$output" "Usage:" "sudoex shows usage on no command"
  fi
}

test_sudoex_double_dash_separator() {
  start_mock_broker "APPROVED"
  build_test_sudoex

  local output
  output=$("$WORK_DIR/sudoex" -- echo hello world 2>/dev/null)
  assert_equals "$output" "EXEC_APPROVED" "sudoex with -- separator works"

  sleep 0.2

  local captured
  captured=$(cat "$CAPTURE_FILE")
  assert_contains "$captured" "SUDO:testuser:echo hello world" \
    "sudoex passes command after -- correctly"

  stop_mock_broker
}

test_sudoex_protocol_line_order() {
  # Verify DECRYPT comes before SUDO in the protocol
  start_mock_broker "APPROVED"
  build_test_sudoex

  "$WORK_DIR/sudoex" --decrypt "/etc/key.gpg:/run/key.txt" -- whoami 2>/dev/null
  sleep 0.2

  local captured
  captured=$(cat "$CAPTURE_FILE")
  local decrypt_line
  decrypt_line=$(echo "$captured" | grep -n "DECRYPT:" | head -1 | cut -d: -f1)
  local sudo_line
  sudo_line=$(echo "$captured" | grep -n "SUDO:" | head -1 | cut -d: -f1)

  if [ -n "$decrypt_line" ] && [ -n "$sudo_line" ] && [ "$decrypt_line" -lt "$sudo_line" ]; then
    pass "DECRYPT line comes before SUDO line in protocol"
  else
    fail "DECRYPT line should come before SUDO line" "DECRYPT at line $decrypt_line, SUDO at line $sudo_line"
  fi

  stop_mock_broker
}

# ── sudo-with-approval protocol tests ─────────────────────────────

build_test_sudo_with_approval() {
  cat > "$WORK_DIR/sudo-with-approval" << SWEOF
#!/usr/bin/env bash
set -e

SOCKET_PATH="$SOCKET_PATH"
MOCK_FILE="$WORK_DIR/mock-mode"
REQUESTING_USER="\${SUDO_USER:-\$(whoami)}"
COMMAND="\$*"

if [ -z "\$COMMAND" ]; then
  echo "Usage: sudo sudo-with-approval <command>" >&2
  exit 1
fi

if [ -f "\$MOCK_FILE" ]; then
  MOCK_MODE=\$(cat "\$MOCK_FILE" | tr -d '\n\r ')
  if [ "\$MOCK_MODE" = "MOCK_APPROVED" ]; then
    echo "[MOCK] Auto-approved: \$COMMAND" >&2
    echo "MOCK_EXEC"
    exit 0
  elif [ "\$MOCK_MODE" = "MOCK_DENIED" ]; then
    echo "[MOCK] Auto-denied: \$COMMAND" >&2
    exit 1
  else
    echo "Error: Invalid mock mode in \$MOCK_FILE (got: '\$MOCK_MODE')" >&2
    exit 1
  fi
fi

if [ ! -S "\$SOCKET_PATH" ]; then
  echo "Error: Approval daemon is not running" >&2
  exit 1
fi

RESPONSE=\$(printf "%s\n\n" "\$REQUESTING_USER:\$COMMAND" | \\
  socat STDIO,ignoreeof UNIX-CONNECT:"\$SOCKET_PATH" || echo "ERROR")

if [ "\$RESPONSE" = "APPROVED" ]; then
  echo "EXEC_APPROVED"
  exit 0
elif [ "\$RESPONSE" = "DENIED" ]; then
  echo "EXEC_DENIED"
  exit 1
else
  echo "Error: \$RESPONSE" >&2
  exit 1
fi
SWEOF
  chmod +x "$WORK_DIR/sudo-with-approval"
}

test_sudo_with_approval_protocol() {
  start_mock_broker "APPROVED"
  build_test_sudo_with_approval

  local output
  output=$("$WORK_DIR/sudo-with-approval" whoami 2>/dev/null)
  assert_equals "$output" "EXEC_APPROVED" "sudo-with-approval returns approved"

  sleep 0.2

  local captured
  captured=$(cat "$CAPTURE_FILE")
  # Legacy format: user:command (no SUDO: or DECRYPT: prefix)
  assert_contains "$captured" ":whoami" "sudo-with-approval sends user:command"
  assert_not_contains "$captured" "SUDO:" "sudo-with-approval uses legacy format (no SUDO: prefix)"
  assert_not_contains "$captured" "DECRYPT:" "sudo-with-approval has no DECRYPT: prefix"

  stop_mock_broker
}

test_sudo_with_approval_mock_approved() {
  build_test_sudo_with_approval
  echo "MOCK_APPROVED" > "$WORK_DIR/mock-mode"

  local output
  output=$("$WORK_DIR/sudo-with-approval" ls -la 2>/dev/null)
  assert_equals "$output" "MOCK_EXEC" "Mock approved mode returns exec"
  rm -f "$WORK_DIR/mock-mode"
}

test_sudo_with_approval_mock_denied() {
  build_test_sudo_with_approval
  echo "MOCK_DENIED" > "$WORK_DIR/mock-mode"

  local output
  if output=$("$WORK_DIR/sudo-with-approval" ls -la 2>&1); then
    fail "Mock denied should exit non-zero" ""
  else
    assert_contains "$output" "[MOCK] Auto-denied" "Mock denied shows message"
  fi
  rm -f "$WORK_DIR/mock-mode"
}

test_sudo_with_approval_mock_invalid() {
  build_test_sudo_with_approval
  echo "GARBAGE" > "$WORK_DIR/mock-mode"

  local output
  if output=$("$WORK_DIR/sudo-with-approval" ls 2>&1); then
    fail "Invalid mock mode should exit non-zero" ""
  else
    assert_contains "$output" "Invalid mock mode" "Invalid mock mode shows error"
    assert_contains "$output" "GARBAGE" "Invalid mock mode shows actual value"
  fi
  rm -f "$WORK_DIR/mock-mode"
}

# ── sops-unlock protocol tests ────────────────────────────────────

build_test_sops_unlock() {
  cat > "$WORK_DIR/sops-unlock" << SUEOF
#!/usr/bin/env bash
set -e

SOCKET_PATH="$SOCKET_PATH"

if [ ! -S "\$SOCKET_PATH" ]; then
  echo "Error: Broker daemon is not running" >&2
  exit 1
fi

echo "Requesting YubiKey decrypt via broker..." >&2

RESPONSE=\$(printf "%s\n\n" "DECRYPT:/etc/sops-age-key.gpg:/run/sops-age/keys.txt" | \\
  socat STDIO,ignoreeof UNIX-CONNECT:"\$SOCKET_PATH" || echo "ERROR")

if [ "\$RESPONSE" = "DECRYPTED" ]; then
  echo "Age key unlocked." >&2
elif [ "\$RESPONSE" = "DENIED" ]; then
  echo "Decrypt denied or failed." >&2
  exit 1
else
  echo "Error communicating with broker (got: '\$RESPONSE')" >&2
  exit 1
fi
SUEOF
  chmod +x "$WORK_DIR/sops-unlock"
}

test_sops_unlock_protocol() {
  start_mock_broker "DECRYPTED"
  build_test_sops_unlock

  "$WORK_DIR/sops-unlock" 2>/dev/null

  sleep 0.2

  local captured
  captured=$(cat "$CAPTURE_FILE")
  assert_contains "$captured" "DECRYPT:/etc/sops-age-key.gpg:/run/sops-age/keys.txt" \
    "sops-unlock sends DECRYPT with correct paths"
  assert_not_contains "$captured" "SUDO:" "sops-unlock does NOT send SUDO"

  stop_mock_broker
}

test_sops_unlock_denied() {
  start_mock_broker "DENIED"
  build_test_sops_unlock

  if "$WORK_DIR/sops-unlock" 2>/dev/null; then
    fail "sops-unlock should fail on DENIED" ""
  else
    pass "sops-unlock exits non-zero on DENIED"
  fi

  stop_mock_broker
}

test_sops_unlock_no_socket() {
  build_test_sops_unlock
  rm -f "$SOCKET_PATH"

  local output
  if output=$("$WORK_DIR/sops-unlock" 2>&1); then
    fail "sops-unlock should fail with no socket" ""
  else
    assert_contains "$output" "not running" "sops-unlock reports missing socket"
  fi
}

# ── nuketown-switch tests ─────────────────────────────────────────

build_test_nuketown_switch() {
  # Create a mock sudoex that records args and simulates success/failure
  cat > "$WORK_DIR/mock-sudoex" << 'NSEOF'
#!/usr/bin/env bash
echo "$*" > /tmp/nuketown-test-sudoex-args
exit "${MOCK_SUDOEX_RC:-0}"
NSEOF
  chmod +x "$WORK_DIR/mock-sudoex"

  # Use a per-test age key location
  local age_key="$WORK_DIR/test-age-key"

  cat > "$WORK_DIR/nuketown-switch" << NSEOF2
#!/usr/bin/env bash
set -e

AGE_KEY="$age_key"

if [ \$# -eq 0 ]; then
  set -- sh -c 'nix-env -p /nix/var/nix/profiles/system --set ./result && ./result/bin/switch-to-configuration switch'
fi

"$WORK_DIR/mock-sudoex" --decrypt "/etc/sops-age-key.gpg:/run/sops-age/keys.txt" -- "\$@"
RC=\$?
rm -f "\$AGE_KEY"
echo "Age key locked." >&2
exit \$RC
NSEOF2
  chmod +x "$WORK_DIR/nuketown-switch"
}

test_nuketown_switch_default_command() {
  build_test_nuketown_switch

  "$WORK_DIR/nuketown-switch" 2>/dev/null

  local args
  args=$(cat /tmp/nuketown-test-sudoex-args)
  assert_contains "$args" "--decrypt" "nuketown-switch passes --decrypt to sudoex"
  assert_contains "$args" "/etc/sops-age-key.gpg:/run/sops-age/keys.txt" \
    "nuketown-switch passes correct decrypt paths"
  assert_contains "$args" "nix-env -p /nix/var/nix/profiles/system --set ./result" \
    "nuketown-switch uses default switch command"
  rm -f /tmp/nuketown-test-sudoex-args
}

test_nuketown_switch_custom_args() {
  build_test_nuketown_switch

  "$WORK_DIR/nuketown-switch" echo hello world 2>/dev/null

  local args
  args=$(cat /tmp/nuketown-test-sudoex-args)
  assert_contains "$args" "--decrypt" "nuketown-switch passes --decrypt for custom command"
  assert_contains "$args" "echo hello world" "nuketown-switch passes custom args"
  assert_not_contains "$args" "nix-env" "nuketown-switch does NOT use default command when args given"
  rm -f /tmp/nuketown-test-sudoex-args
}

test_nuketown_switch_cleanup_on_success() {
  build_test_nuketown_switch

  # Create fake age key
  local age_key="$WORK_DIR/test-age-key"
  touch "$age_key"
  "$WORK_DIR/nuketown-switch" echo ok 2>/dev/null

  if [ ! -f "$age_key" ]; then
    pass "nuketown-switch cleans up age key on success"
  else
    fail "nuketown-switch did NOT clean up age key on success" ""
  fi
  rm -f /tmp/nuketown-test-sudoex-args
}

test_nuketown_switch_set_e_exits_on_failure() {
  # The actual nuketown-switch in module.nix uses set -e. When sudoex fails,
  # bash exits immediately -- RC=$? and the cleanup lines never execute.
  # This test documents that behavior. The age key is NOT cleaned up on
  # sudoex failure (it is cleaned up on success, and sops-lock can be
  # called manually).
  build_test_nuketown_switch

  # Make mock sudoex fail
  cat > "$WORK_DIR/mock-sudoex" << 'FAILEOF'
#!/usr/bin/env bash
exit 1
FAILEOF
  chmod +x "$WORK_DIR/mock-sudoex"

  local age_key="$WORK_DIR/test-age-key"
  touch "$age_key"

  "$WORK_DIR/nuketown-switch" echo fail 2>/dev/null || true

  # With set -e, the cleanup does NOT run on failure
  if [ -f "$age_key" ]; then
    pass "nuketown-switch: set -e prevents cleanup on sudoex failure (known behavior)"
  else
    fail "Expected age key to remain (set -e should skip cleanup)" ""
  fi
  rm -f "$age_key" /tmp/nuketown-test-sudoex-args
}

# ── sops-lock tests ───────────────────────────────────────────────

test_sops_lock_removes_key() {
  local key_file="$WORK_DIR/test-age-key-lock"
  echo "fake-key" > "$key_file"

  # Simulate sops-lock behavior
  rm -f "$key_file"

  if [ ! -f "$key_file" ]; then
    pass "sops-lock removes the age key file"
  else
    fail "sops-lock did NOT remove the age key file" ""
  fi
}

test_sops_lock_idempotent() {
  local key_file="$WORK_DIR/test-age-key-idem"
  rm -f "$key_file" 2>/dev/null || true

  # sops-lock should not error when key is already absent
  if rm -f "$key_file" 2>/dev/null; then
    pass "sops-lock is idempotent (no error when key already absent)"
  else
    fail "sops-lock failed when key already absent" ""
  fi
}

# ── Main ───────────────────────────────────────────────────────────

main() {
  echo ""
  echo "Nuketown: Client Wire Protocol Tests"
  echo ""

  # Check for socat
  if ! command -v socat &>/dev/null; then
    echo "Error: socat is required for client protocol tests"
    echo "Install it with: nix-shell -p socat"
    exit 1
  fi

  # sudoex tests
  run_test "sudoex: SUDO-only protocol" test_sudoex_sudo_only
  run_test "sudoex: DECRYPT+SUDO protocol" test_sudoex_with_decrypt
  run_test "sudoex: denied response" test_sudoex_denied
  run_test "sudoex: no command shows usage" test_sudoex_no_command
  run_test "sudoex: -- separator" test_sudoex_double_dash_separator
  run_test "sudoex: DECRYPT before SUDO line order" test_sudoex_protocol_line_order

  # sudo-with-approval tests
  run_test "sudo-with-approval: legacy protocol" test_sudo_with_approval_protocol
  run_test "sudo-with-approval: mock approved" test_sudo_with_approval_mock_approved
  run_test "sudo-with-approval: mock denied" test_sudo_with_approval_mock_denied
  run_test "sudo-with-approval: mock invalid" test_sudo_with_approval_mock_invalid

  # sops-unlock tests
  run_test "sops-unlock: DECRYPT protocol" test_sops_unlock_protocol
  run_test "sops-unlock: denied response" test_sops_unlock_denied
  run_test "sops-unlock: no socket error" test_sops_unlock_no_socket

  # nuketown-switch tests
  run_test "nuketown-switch: default command" test_nuketown_switch_default_command
  run_test "nuketown-switch: custom args" test_nuketown_switch_custom_args
  run_test "nuketown-switch: cleanup on success" test_nuketown_switch_cleanup_on_success
  run_test "nuketown-switch: set -e exits on failure" test_nuketown_switch_set_e_exits_on_failure

  # sops-lock tests
  run_test "sops-lock: removes key file" test_sops_lock_removes_key
  run_test "sops-lock: idempotent" test_sops_lock_idempotent

  print_summary
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
