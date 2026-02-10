#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

test_vm_connection() {
  echo "TEST: Starting test_vm_connection" >&2
  local output
  output=$(vm_run "whoami")
  echo "TEST: Got output: $output" >&2
  assert_equals "$output" "human" "Should be logged in as human"
  echo "TEST: Assert completed" >&2
}

test_simple_command() {
  local output=$(vm_run "echo hello")
  assert_contains "$output" "hello" "Should echo hello"
}

main() {
  echo "Simple Connection Test"
  vm_wait 30 || exit 1
  run_test "VM connection" test_vm_connection
  run_test "Simple command" test_simple_command
  print_summary
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
