#!/usr/bin/env bash
# Test runner for nuketown tests
# Usage: ./run-tests.sh [test-name...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Find all test files
find_tests() {
  find "$SCRIPT_DIR" -name "*.sh" ! -name "lib.sh" ! -name "run-tests.sh" -type f | sort
}

# Run a single test file
run_test_file() {
  local test_file="$1"
  local test_name=$(basename "$test_file" .sh)

  echo ""
  echo "════════════════════════════════════════"
  echo "Running test suite: $test_name"
  echo "════════════════════════════════════════"

  # Redirect stdin to /dev/null so test doesn't consume pipe data
  bash "$test_file" < /dev/null
}

# Main execution
main() {
  local failed=0
  local total=0

  # Check if we need sshpass
  if ! command -v sshpass &> /dev/null; then
    echo "Error: sshpass is required but not found"
    echo "Please run via: nix run .#test"
    exit 1
  fi

  # If specific tests requested, run only those
  if [ $# -gt 0 ]; then
    for test_name in "$@"; do
      local test_file="$SCRIPT_DIR/${test_name}.sh"
      if [ ! -f "$test_file" ]; then
        test_file="$SCRIPT_DIR/${test_name}"
      fi

      if [ -f "$test_file" ]; then
        total=$((total + 1))
        if ! run_test_file "$test_file"; then
          failed=$((failed + 1))
        fi
      else
        echo "Error: Test file not found: $test_name"
        failed=$((failed + 1))
      fi
    done
  else
    # Run all tests
    while IFS= read -r test_file; do
      total=$((total + 1))
      if ! run_test_file "$test_file"; then
        failed=$((failed + 1))
      fi
    done < <(find_tests)
  fi

  # Final summary
  echo ""
  echo "════════════════════════════════════════"
  echo "Overall Summary"
  echo "════════════════════════════════════════"
  echo "Test suites run: $total"

  if [ $failed -eq 0 ]; then
    echo -e "\033[0;32m✓ All test suites passed!\033[0m"
    return 0
  else
    echo -e "\033[0;31m✗ $failed test suite(s) failed\033[0m"
    return 1
  fi
}

main "$@"
