#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

test_linger_enabled() {
  local output=$(vm_run "loginctl show-user ada -p Linger --value")
  assert_equals "$output" "yes" "User linger should be enabled for daemon agent"
}

test_daemon_service_exists() {
  # Check the unit file exists in ada's systemd user config
  local output=$(vm_run "sudo -u ada XDG_RUNTIME_DIR=/run/user/1100 systemctl --user list-unit-files nuketown-daemon.service 2>&1")
  assert_contains "$output" "nuketown-daemon.service" "Daemon unit file should exist"
}

test_daemon_service_running() {
  # Give the service a moment to start, then check
  vm_run "sleep 2" >/dev/null 2>&1 || true
  local output=$(vm_run "sudo -u ada XDG_RUNTIME_DIR=/run/user/1100 systemctl --user is-active nuketown-daemon.service 2>&1")
  assert_equals "$output" "active" "Daemon service should be active"
}

test_socket_exists() {
  local output=$(vm_run "sudo -u ada test -S /run/user/1100/nuketown-daemon.sock && echo exists || echo missing")
  assert_equals "$output" "exists" "Daemon socket should exist"
}

test_status_request() {
  # Send a status request to the daemon socket and check response
  local output=$(vm_run "sudo -u ada bash -c 'echo \"{\\\"type\\\": \\\"status\\\"}\" | socat - UNIX-CONNECT:/run/user/1100/nuketown-daemon.sock'")
  assert_contains "$output" '"status"' "Status response should contain status field"
  assert_contains "$output" '"idle"' "Daemon should be idle"
}

test_repos_toml() {
  local output=$(vm_run "sudo -u ada cat /agents/ada/.config/nuketown/repos.toml 2>&1")
  assert_contains "$output" "hello" "repos.toml should contain hello repo"
}

main() {
  vm_wait 60 || exit 1

  run_test "Linger enabled for daemon agent" test_linger_enabled
  run_test "Daemon service unit exists" test_daemon_service_exists
  run_test "Daemon service is running" test_daemon_service_running
  run_test "Daemon socket exists" test_socket_exists
  run_test "Status request returns idle" test_status_request
  run_test "repos.toml generated" test_repos_toml

  print_summary
}

main "$@"
