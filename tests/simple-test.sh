#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

test_vm_connection() {
  local output
  output=$(vm_run "whoami")
  assert_equals "$output" "human" "Should be logged in as human"
}

test_agent_user() {
  local output=$(vm_run "id ada")
  assert_contains "$output" "uid=1100(ada)" "Agent user has correct uid"
  assert_contains "$output" "gid=1100(ada)" "Agent user has correct gid"
}

test_agent_home() {
  local output=$(vm_run "stat -c '%U %a' /agents/ada")
  assert_contains "$output" "ada" "Home directory owned by agent"
}

test_identity_toml() {
  local toml=$(vm_run "sudo -u ada cat /agents/ada/.config/nuketown/identity.toml")
  assert_contains "$toml" 'name = "ada"' "TOML has name"
  assert_contains "$toml" 'role = "software"' "TOML has role"
  assert_contains "$toml" 'email = "ada@nuketown.test"' "TOML has email"
  assert_contains "$toml" 'domain = "nuketown.test"' "TOML has domain"
  assert_contains "$toml" 'home = "/agents/ada"' "TOML has home"
  assert_contains "$toml" 'uid = 1100' "TOML has uid"
  assert_contains "$toml" "Test software agent" "TOML has description"
}

test_git_config() {
  local name=$(vm_run "sudo -u ada git config --global user.name")
  local email=$(vm_run "sudo -u ada git config --global user.email")
  assert_equals "$name" "ada" "Git user.name is ada"
  assert_equals "$email" "ada@nuketown.test" "Git user.email is correct"
}

test_claude_code_agent_prompt() {
  local prompt=$(vm_run "sudo -u ada cat /agents/ada/.claude/agents/ada-software.md")
  assert_contains "$prompt" "name: ada-software" "Prompt has agent name"
  assert_contains "$prompt" "You are Ada" "Prompt addresses agent by display name"
  assert_contains "$prompt" "uid 1100" "Prompt has uid"
  assert_contains "$prompt" "ada@nuketown.test" "Prompt has email"
  assert_contains "$prompt" "## Sudo" "Prompt has sudo section"
  assert_contains "$prompt" "ephemeral" "Prompt describes ephemeral home"
}

test_packages_available() {
  local output=$(vm_run "sudo -u ada bash -l -c 'which git && which rg && which jq'")
  assert_contains "$output" "git" "git is available"
  assert_contains "$output" "rg" "ripgrep is available"
  assert_contains "$output" "jq" "jq is available"
}

test_direnv_configured() {
  local output=$(vm_run "sudo -u ada bash -l -c 'which direnv'")
  assert_contains "$output" "direnv" "direnv is available"
}

main() {
  echo "Nuketown Agent E2E Tests"
  vm_wait 30 || exit 1

  run_test "VM connection" test_vm_connection
  run_test "Agent user creation" test_agent_user
  run_test "Agent home directory" test_agent_home
  run_test "Identity TOML" test_identity_toml
  run_test "Git configuration" test_git_config
  run_test "Claude Code agent prompt" test_claude_code_agent_prompt
  run_test "Base packages available" test_packages_available
  run_test "Direnv configured" test_direnv_configured

  print_summary
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
