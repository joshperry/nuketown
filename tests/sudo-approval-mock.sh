#!/usr/bin/env bash
# Test suite for mock sudo approval system

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Test 1: MOCK_APPROVED allows sudo execution
test_mock_approved() {
  # Verify mock file is set to APPROVED
  local mode=$(vm_run "cat /run/sudo-approval/mode")
  assert_equals "$mode" "MOCK_APPROVED" "Mock file should be MOCK_APPROVED"

  # Run sudo as ada agent
  local output=$(vm_run_as ada "sudo whoami 2>&1")

  # Verify it succeeded and shows root
  assert_contains "$output" "root" "Command should execute as root"
  assert_contains "$output" "[MOCK] Auto-approved" "Should show mock approval message"
}

# Test 2: MOCK_DENIED blocks sudo execution
test_mock_denied() {
  # Change mock file to DENIED
  vm_run "echo MOCK_DENIED > /run/sudo-approval/mode"

  local mode=$(vm_run "cat /run/sudo-approval/mode")
  assert_equals "$mode" "MOCK_DENIED" "Mock file should be MOCK_DENIED"

  # Try to run sudo as ada (should fail)
  local output
  if output=$(vm_run_as ada "sudo whoami 2>&1"); then
    fail "Command should have been denied" "Got output: $output"
  else
    pass "Command correctly denied"
    assert_contains "$output" "[MOCK] Auto-denied" "Should show mock denial message"
  fi
}

# Test 3: Can toggle back to APPROVED
test_mock_toggle_back() {
  # Change back to APPROVED
  vm_run "echo MOCK_APPROVED > /run/sudo-approval/mode"

  local mode=$(vm_run "cat /run/sudo-approval/mode")
  assert_equals "$mode" "MOCK_APPROVED" "Mock file should be MOCK_APPROVED again"

  # Run sudo as ada (should succeed)
  local output=$(vm_run_as ada "sudo whoami 2>&1")

  assert_contains "$output" "root" "Command should execute as root"
  assert_contains "$output" "[MOCK] Auto-approved" "Should show mock approval message"
}

# Test 4: Invalid mock mode errors clearly
test_invalid_mock_mode() {
  # Set invalid mode
  vm_run "echo INVALID_MODE > /run/sudo-approval/mode"

  # Try to run sudo (should fail with clear error)
  local output
  if output=$(vm_run_as ada "sudo whoami 2>&1"); then
    fail "Invalid mock mode should cause error" "Got output: $output"
  else
    pass "Invalid mock mode correctly rejected"
    assert_contains "$output" "Invalid mock mode" "Should show invalid mode error"
    assert_contains "$output" "INVALID_MODE" "Should show what was found"
  fi

  # Clean up for next test
  vm_run "echo MOCK_APPROVED > /run/sudo-approval/mode"
}

# Test 5: Mock file ownership prevents agent tampering
test_mock_file_security() {
  # Try to modify mock file as ada (should fail)
  local output
  if output=$(vm_run_as ada "echo MOCK_APPROVED > /run/sudo-approval/mode 2>&1"); then
    fail "Agent should not be able to modify mock file" "Got output: $output"
  else
    pass "Agent correctly denied write access to mock file"
    assert_contains "$output" "Permission denied" "Should show permission denied"
  fi
}

# Main execution
main() {
  echo -e "${BLUE}═══════════════════════════════════════${NC}"
  echo -e "${BLUE}Nuketown: Mock Sudo Approval Tests${NC}"
  echo -e "${BLUE}═══════════════════════════════════════${NC}"

  # Wait for VM to be ready
  vm_wait 60 || exit 1

  # Run all tests
  run_test "MOCK_APPROVED allows execution" test_mock_approved
  run_test "MOCK_DENIED blocks execution" test_mock_denied
  run_test "Can toggle back to APPROVED" test_mock_toggle_back
  run_test "Invalid mock mode errors clearly" test_invalid_mock_mode
  run_test "Mock file security prevents tampering" test_mock_file_security

  # Print summary and return exit code
  print_summary
}

# Only run if executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
