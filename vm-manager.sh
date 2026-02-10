#!/usr/bin/env bash
# VM manager for nuketown testing
# Usage: ./vm-manager.sh {start|stop|test|status} [vm-name]

set -euo pipefail

VM_NAME="${2:-test-basic}"
VM_PID_FILE="/tmp/nuketown-vm-${VM_NAME}.pid"
VM_BUILD_RESULT="result-vm-${VM_NAME}"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

cmd_start() {
  if is_running; then
    echo -e "${GREEN}VM is already running (PID: $(cat "$VM_PID_FILE"))${NC}"
    return 0
  fi

  echo -e "${BLUE}Building VM: $VM_NAME${NC}"
  nix build ".#nixosConfigurations.${VM_NAME}.config.system.build.vm" -o "$VM_BUILD_RESULT"

  echo -e "${BLUE}Starting VM in headless mode...${NC}"
  QEMU_OPTS="-nographic" "$VM_BUILD_RESULT/bin/run-nixos-vm" >/tmp/vm.log 2>&1 &
  local pid=$!

  echo $pid > "$VM_PID_FILE"
  echo -e "${GREEN}✓ VM started (PID: $pid)${NC}"

  echo -e "${BLUE}Waiting for VM to be ready...${NC}"
  if wait_for_ssh 60; then
    echo -e "${GREEN}✓ VM is ready for testing${NC}"
    return 0
  else
    echo -e "${RED}✗ VM failed to become ready${NC}"
    cmd_stop
    return 1
  fi
}

cmd_stop() {
  if ! is_running; then
    echo -e "${BLUE}VM is not running${NC}"
    rm -f "$VM_PID_FILE"
    return 0
  fi

  local pid=$(cat "$VM_PID_FILE")
  echo -e "${BLUE}Stopping VM (PID: $pid)...${NC}"

  if kill "$pid" 2>/dev/null; then
    # Wait for process to die
    local count=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.5
      ((count++))
      if [ $count -gt 20 ]; then
        echo -e "${RED}VM didn't stop gracefully, forcing...${NC}"
        kill -9 "$pid" 2>/dev/null || true
        break
      fi
    done
  fi

  rm -f "$VM_PID_FILE"
  rm -f nixos.qcow2  # Clean up disk image

  echo -e "${GREEN}✓ VM stopped${NC}"
}

cmd_status() {
  if is_running; then
    local pid=$(cat "$VM_PID_FILE")
    echo -e "${GREEN}✓ VM is running (PID: $pid)${NC}"

    if can_ssh; then
      echo -e "${GREEN}✓ SSH is responding${NC}"
    else
      echo -e "${RED}✗ SSH is not responding${NC}"
    fi

    return 0
  else
    echo -e "${BLUE}VM is not running${NC}"
    rm -f "$VM_PID_FILE"
    return 1
  fi
}

cmd_test() {
  local test_name="${3:-}"

  if ! is_running || ! can_ssh; then
    echo -e "${BLUE}Starting VM for testing...${NC}"
    cmd_start || return 1
  fi

  # Use NUKETOWN_TEST_RUNNER if set (from nix run), otherwise use relative path
  local test_runner="${NUKETOWN_TEST_RUNNER:-./tests/run-tests.sh}"

  echo -e "${BLUE}Running tests...${NC}"
  echo "DEBUG: test_runner=$test_runner" >&2
  echo "DEBUG: About to execute test runner" >&2

  if [ -n "$test_name" ]; then
    echo "DEBUG: Running with test_name: $test_name" >&2
    "$test_runner" "$test_name"
  else
    echo "DEBUG: Running all tests" >&2
    "$test_runner"
  fi
  local exit_code=$?
  echo "DEBUG: Test runner exited with code: $exit_code" >&2
  return $exit_code
}

cmd_restart() {
  cmd_stop
  cmd_start
}

# Helper functions
is_running() {
  [ -f "$VM_PID_FILE" ] && kill -0 "$(cat "$VM_PID_FILE")" 2>/dev/null
}

can_ssh() {
  sshpass -p test ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=2 \
    -o LogLevel=ERROR \
    -p 2222 \
    human@localhost \
    "true" &>/dev/null
}

wait_for_ssh() {
  local timeout="${1:-60}"
  local start=$(date +%s)

  while true; do
    if can_ssh; then
      return 0
    fi

    local elapsed=$(($(date +%s) - start))
    if [ $elapsed -gt $timeout ]; then
      return 1
    fi

    sleep 1
  done
}

# Command dispatch
cmd="${1:-}"
case "$cmd" in
  start)
    cmd_start
    ;;
  stop)
    cmd_stop
    ;;
  status)
    cmd_status
    ;;
  test)
    shift
    cmd_test "$@"
    ;;
  restart)
    cmd_restart
    ;;
  *)
    echo "Usage: $0 {start|stop|status|test|restart} [vm-name] [test-name]"
    echo ""
    echo "Commands:"
    echo "  start     - Build and start the test VM"
    echo "  stop      - Stop the running VM"
    echo "  status    - Check if VM is running"
    echo "  test      - Run tests (starts VM if needed)"
    echo "  restart   - Stop and start the VM"
    echo ""
    echo "Examples:"
    echo "  $0 start              # Start test-basic VM"
    echo "  $0 start test-multi   # Start test-multi VM"
    echo "  $0 test               # Run all tests"
    echo "  $0 test test-basic sudo-approval-mock  # Run specific test"
    echo "  $0 stop               # Stop VM"
    exit 1
    ;;
esac
