#!/usr/bin/env bash
# Test library for nuketown tests
# Provides utilities for VM interaction and assertions

set -euo pipefail

# Configuration
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_SSH_USER="${VM_SSH_USER:-human}"
VM_SSH_PASS="${VM_SSH_PASS:-test}"
VM_SSH_HOST="${VM_SSH_HOST:-localhost}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# SSH helper - runs command on VM
vm_run() {
  local cmd="$*"
  sshpass -p "$VM_SSH_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -p "$VM_SSH_PORT" \
    "${VM_SSH_USER}@${VM_SSH_HOST}" \
    "$cmd" 2>&1
}

# SSH helper - runs command as specific user
vm_run_as() {
  local user="$1"
  shift
  local cmd="$*"
  vm_run "sudo -u $user bash -l -c '$cmd'"
}

# Copy file to VM
vm_copy() {
  local src="$1"
  local dst="$2"
  sshpass -p "$VM_SSH_PASS" scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -P "$VM_SSH_PORT" \
    "$src" "${VM_SSH_USER}@${VM_SSH_HOST}:$dst"
}

# Wait for VM to be ready
vm_wait() {
  local timeout="${1:-60}"
  local start=$(date +%s)

  echo -e "${BLUE}Waiting for VM to be ready (timeout: ${timeout}s)...${NC}"

  while true; do
    if vm_run "true" &>/dev/null; then
      echo -e "${GREEN}✓ VM is ready${NC}"
      return 0
    fi

    local elapsed=$(($(date +%s) - start))
    if [ $elapsed -gt $timeout ]; then
      echo -e "${RED}✗ VM failed to become ready after ${timeout}s${NC}"
      return 1
    fi

    sleep 1
  done
}

# Assertions
assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-Output should contain '$needle'}"

  if echo "$haystack" | grep -qF "$needle"; then
    pass "$message"
    return 0
  else
    fail "$message" "Expected to find: $needle\nActual output:\n$haystack"
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-Output should not contain '$needle'}"

  if ! echo "$haystack" | grep -qF "$needle"; then
    pass "$message"
    return 0
  else
    fail "$message" "Did not expect to find: $needle\nActual output:\n$haystack"
    return 1
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local message="${3:-Values should be equal}"

  if [ "$actual" = "$expected" ]; then
    pass "$message"
    return 0
  else
    fail "$message" "Expected: $expected\nActual: $actual"
    return 1
  fi
}

# Test reporting
pass() {
  local message="$1"
  echo -e "${GREEN}  ✓${NC} $message"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  local message="$1"
  local details="${2:-}"

  echo -e "${RED}  ✗${NC} $message"
  if [ -n "$details" ]; then
    echo -e "${RED}    $details${NC}" | sed 's/^/    /'
  fi
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Test runner
run_test() {
  local test_name="$1"
  local test_func="$2"

  TESTS_RUN=$((TESTS_RUN + 1))

  echo ""
  echo "Running: $test_name"

  if $test_func; then
    return 0
  else
    return 1
  fi
}

# Summary
print_summary() {
  echo -e "\n${BLUE}═══════════════════════════════════════${NC}"
  echo -e "${BLUE}Test Summary${NC}"
  echo -e "${BLUE}═══════════════════════════════════════${NC}"
  echo -e "Total:   $TESTS_RUN"
  echo -e "${GREEN}Passed:  $TESTS_PASSED${NC}"

  if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed:  $TESTS_FAILED${NC}"
    return 1
  else
    echo -e "\n${GREEN}✓ All tests passed!${NC}"
    return 0
  fi
}
