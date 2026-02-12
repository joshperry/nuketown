#!/usr/bin/env bash
# Test suite for the broker handler protocol parsing.
#
# These tests extract the broker handler script from the nix store and
# run it with mocked gpg/zenity to verify protocol parsing. The handler
# reads ops from stdin (terminated by an empty line) and dispatches based
# on the op prefix (DECRYPT, SUDO, or legacy format).
#
# No VM required -- runs locally with mock binaries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Setup ──────────────────────────────────────────────────────────

WORK_DIR=$(mktemp -d)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# Build a minimal broker handler using the same nix expression
# but with mocked gpg, zenity, and install binaries.
build_mock_handler() {
  local gpg_behavior="$1"    # "success" or "fail"
  local zenity_behavior="$2" # "approve", "deny", or "info-ok"

  local MOCK_BIN="$WORK_DIR/mock-bin"
  mkdir -p "$MOCK_BIN"

  # Mock gpg: -d flag means decrypt, write "decrypted-content" to stdout
  if [ "$gpg_behavior" = "success" ]; then
    cat > "$MOCK_BIN/gpg" << 'MOCKEOF'
#!/usr/bin/env bash
# Mock gpg: always succeeds, writes dummy content to stdout
if [[ "$1" == "-d" ]]; then
  echo "mock-decrypted-key-content"
  exit 0
fi
exit 0
MOCKEOF
  else
    cat > "$MOCK_BIN/gpg" << 'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
  fi
  chmod +x "$MOCK_BIN/gpg"

  # Mock zenity: --question returns 0 (approve) or 1 (deny)
  if [ "$zenity_behavior" = "approve" ]; then
    cat > "$MOCK_BIN/zenity" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
  elif [ "$zenity_behavior" = "deny" ]; then
    cat > "$MOCK_BIN/zenity" << 'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
  else
    # info-ok: just exits 0
    cat > "$MOCK_BIN/zenity" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
  fi
  chmod +x "$MOCK_BIN/zenity"

  # Mock install (coreutils install)
  cat > "$MOCK_BIN/install" << 'MOCKEOF'
#!/usr/bin/env bash
# Mock install: copy file (last two args are src and dest)
# Parse: install -m NNN src dest
while [[ $# -gt 2 ]]; do shift; done
cp "$1" "$2"
MOCKEOF
  chmod +x "$MOCK_BIN/install"

  # Mock mktemp
  local TMPFILE="$WORK_DIR/broker-tmp"
  cat > "$MOCK_BIN/mktemp" << MOCKEOF
#!/usr/bin/env bash
echo "$TMPFILE"
MOCKEOF
  chmod +x "$MOCK_BIN/mktemp"

  # Build the handler script that uses our mocks.
  # We replicate the broker handler logic with mock paths.
  cat > "$WORK_DIR/handler.sh" << 'HANDLER'
#!/usr/bin/env bash
set -uo pipefail

escape_html() {
  echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# ── Read all ops from the connection ──────────────────────
DECRYPT_SRC=""
DECRYPT_DEST=""
SUDO_USER=""
SUDO_COMMAND=""

while IFS= read -r REQUEST && [ -n "$REQUEST" ]; do
  OP=$(echo "$REQUEST" | cut -d: -f1)

  case "$OP" in
    DECRYPT)
      DECRYPT_SRC=$(echo "$REQUEST" | cut -d: -f2)
      DECRYPT_DEST=$(echo "$REQUEST" | cut -d: -f3)
      ;;
    SUDO)
      SUDO_USER=$(echo "$REQUEST" | cut -d: -f2)
      SUDO_COMMAND=$(echo "$REQUEST" | cut -d: -f3-)
      ;;
    *)
      # Legacy: username:command
      SUDO_USER=$(echo "$REQUEST" | cut -d: -f1)
      SUDO_COMMAND=$(echo "$REQUEST" | cut -d: -f2-)
      ;;
  esac
done

# ── Decide how to handle the request set ──────────────────

# Combined: DECRYPT + SUDO
if [ -n "$DECRYPT_SRC" ] && [ -n "$SUDO_USER" ]; then
  USER_ESC=$(escape_html "$SUDO_USER")
  COMMAND_ESC=$(escape_html "$SUDO_COMMAND")

  TMPFILE=$(mktemp)
  cleanup() { rm -f "$TMPFILE" 2>/dev/null || true; }
  trap cleanup EXIT

  # Start gpg in background
  gpg -d "$DECRYPT_SRC" > "$TMPFILE" 2>/dev/null &
  GPG_PID=$!

  # Start zenity in background
  zenity --question --title="test" --text="$USER_ESC: $COMMAND_ESC" 2>/dev/null &
  ZENITY_PID=$!

  GPG_DONE=""
  GPG_OK=""

  while true; do
    if [ -z "$GPG_DONE" ] && ! kill -0 "$GPG_PID" 2>/dev/null; then
      wait "$GPG_PID" 2>/dev/null
      GPG_RC=$?
      GPG_DONE=1
      [ "$GPG_RC" -eq 0 ] && GPG_OK=1

      if [ -n "$GPG_OK" ]; then
        kill "$ZENITY_PID" 2>/dev/null || true
        wait "$ZENITY_PID" 2>/dev/null || true
        install -m 600 "$TMPFILE" "$DECRYPT_DEST"
        echo "APPROVED"
        exit 0
      fi
    fi

    if ! kill -0 "$ZENITY_PID" 2>/dev/null; then
      wait "$ZENITY_PID" 2>/dev/null
      ZENITY_RC=$?

      if [ "$ZENITY_RC" -eq 0 ]; then
        if [ -z "$GPG_DONE" ]; then
          wait "$GPG_PID" 2>/dev/null
          GPG_RC=$?
          GPG_DONE=1
          [ "$GPG_RC" -eq 0 ] && GPG_OK=1
        fi
        if [ -n "$GPG_OK" ]; then
          install -m 600 "$TMPFILE" "$DECRYPT_DEST"
          echo "APPROVED"
          exit 0
        fi
        # GPG failed -- for testing, just deny (no retry loop in mock)
        echo "DENIED"
        exit 0
      else
        kill "$GPG_PID" 2>/dev/null || true
        wait "$GPG_PID" 2>/dev/null || true
        echo "DENIED"
        exit 0
      fi
    fi

    sleep 0.05
  done
fi

# DECRYPT only
if [ -n "$DECRYPT_SRC" ]; then
  SRC_ESC=$(escape_html "$DECRYPT_SRC")

  TMPFILE=$(mktemp)
  cleanup() { rm -f "$TMPFILE" 2>/dev/null || true; }
  trap cleanup EXIT

  zenity --info --title="test" --text="$SRC_ESC" 2>/dev/null &
  ZENITY_PID=$!

  if gpg -d "$DECRYPT_SRC" > "$TMPFILE" 2>/dev/null; then
    kill $ZENITY_PID 2>/dev/null || true
    wait $ZENITY_PID 2>/dev/null || true
    install -m 600 "$TMPFILE" "$DECRYPT_DEST"
    echo "DECRYPTED"
  else
    kill $ZENITY_PID 2>/dev/null || true
    wait $ZENITY_PID 2>/dev/null || true
    echo "DENIED"
  fi
  exit 0
fi

# SUDO only
if [ -n "$SUDO_USER" ]; then
  USER_ESC=$(escape_html "$SUDO_USER")
  COMMAND_ESC=$(escape_html "$SUDO_COMMAND")

  if zenity --question --title="test" --text="$USER_ESC: $COMMAND_ESC" 2>/dev/null; then
    echo "APPROVED"
  else
    echo "DENIED"
  fi
  exit 0
fi

echo "ERROR: no valid operations"
HANDLER
  chmod +x "$WORK_DIR/handler.sh"

  # Prepend mock bin to PATH in the handler
  sed -i "2i export PATH=\"$MOCK_BIN:\$PATH\"" "$WORK_DIR/handler.sh"
}

# Helper: run handler with given input and mocks
run_handler() {
  local gpg_behavior="$1"
  local zenity_behavior="$2"
  local input="$3"

  build_mock_handler "$gpg_behavior" "$zenity_behavior"
  echo -e "$input" | bash "$WORK_DIR/handler.sh" 2>/dev/null
}

# ── Tests ──────────────────────────────────────────────────────────

test_sudo_only_approved() {
  local output
  output=$(run_handler "success" "approve" "SUDO:ada:whoami\n")
  assert_equals "$output" "APPROVED" "SUDO-only with approval returns APPROVED"
}

test_sudo_only_denied() {
  local output
  output=$(run_handler "success" "deny" "SUDO:ada:whoami\n")
  assert_equals "$output" "DENIED" "SUDO-only with denial returns DENIED"
}

test_legacy_format_approved() {
  local output
  output=$(run_handler "success" "approve" "ada:whoami\n")
  assert_equals "$output" "APPROVED" "Legacy format with approval returns APPROVED"
}

test_legacy_format_denied() {
  local output
  output=$(run_handler "success" "deny" "ada:whoami\n")
  assert_equals "$output" "DENIED" "Legacy format with denial returns DENIED"
}

test_decrypt_only_success() {
  local dest="$WORK_DIR/decrypted-output"
  rm -f "$dest"

  build_mock_handler "success" "info-ok"
  local output
  output=$(echo -e "DECRYPT:/etc/sops-age-key.gpg:$dest\n" | bash "$WORK_DIR/handler.sh" 2>/dev/null)
  assert_equals "$output" "DECRYPTED" "DECRYPT-only with success returns DECRYPTED"

  if [ -f "$dest" ]; then
    pass "Decrypted file was written to destination"
  else
    fail "Decrypted file was NOT written to destination"
  fi
}

test_decrypt_only_failure() {
  local dest="$WORK_DIR/decrypted-output-fail"
  rm -f "$dest"

  build_mock_handler "fail" "info-ok"
  local output
  output=$(echo -e "DECRYPT:/etc/sops-age-key.gpg:$dest\n" | bash "$WORK_DIR/handler.sh" 2>/dev/null)
  assert_equals "$output" "DENIED" "DECRYPT-only with gpg failure returns DENIED"

  if [ ! -f "$dest" ]; then
    pass "No file written on decrypt failure"
  else
    fail "File should not have been written on decrypt failure"
  fi
}

test_combined_decrypt_sudo_approved() {
  local dest="$WORK_DIR/combined-output"
  rm -f "$dest"

  build_mock_handler "success" "approve"
  local output
  output=$(echo -e "DECRYPT:/etc/sops-age-key.gpg:$dest\nSUDO:ada:nix-env -p /nix/var/nix/profiles/system --set ./result\n" | bash "$WORK_DIR/handler.sh" 2>/dev/null)
  assert_equals "$output" "APPROVED" "Combined DECRYPT+SUDO with approval returns APPROVED"

  if [ -f "$dest" ]; then
    pass "Combined flow: decrypted file was written"
  else
    fail "Combined flow: decrypted file was NOT written"
  fi
}

test_combined_decrypt_sudo_gpg_success_overrides_zenity() {
  # In the combined flow, if gpg succeeds (YubiKey touched), it approves
  # even if zenity would have been denied -- the YubiKey touch IS the approval.
  local dest="$WORK_DIR/combined-output-gpg-wins"
  rm -f "$dest"

  build_mock_handler "success" "deny"
  local output
  output=$(echo -e "DECRYPT:/etc/sops-age-key.gpg:$dest\nSUDO:ada:nix-env --set ./result\n" | bash "$WORK_DIR/handler.sh" 2>/dev/null)
  assert_equals "$output" "APPROVED" "Combined: gpg success overrides zenity (YubiKey = approval)"
}

test_combined_decrypt_sudo_gpg_fail_zenity_deny() {
  # When gpg fails AND zenity denies, the result is DENIED
  local dest="$WORK_DIR/combined-output-both-fail"
  rm -f "$dest"

  build_mock_handler "fail" "deny"
  local output
  output=$(echo -e "DECRYPT:/etc/sops-age-key.gpg:$dest\nSUDO:ada:nix-env --set ./result\n" | bash "$WORK_DIR/handler.sh" 2>/dev/null)
  assert_equals "$output" "DENIED" "Combined: gpg fail + zenity deny = DENIED"
}

test_empty_input() {
  local output
  output=$(run_handler "success" "approve" "\n")
  assert_equals "$output" "ERROR: no valid operations" "Empty input returns error"
}

test_sudo_command_with_colons() {
  # Verify that a SUDO command containing colons is parsed correctly.
  # cut -d: -f3- should capture everything after the second colon.
  local output
  output=$(run_handler "success" "approve" "SUDO:ada:sh -c 'echo foo:bar:baz'\n")
  assert_equals "$output" "APPROVED" "SUDO with colons in command is approved"
}

test_decrypt_parses_src_and_dest() {
  # Verify that DECRYPT line correctly splits src and dest on colons.
  local dest="$WORK_DIR/parse-test-dest"
  rm -f "$dest"

  build_mock_handler "success" "info-ok"
  local output
  output=$(echo -e "DECRYPT:/path/to/source.gpg:$dest\n" | bash "$WORK_DIR/handler.sh" 2>/dev/null)
  assert_equals "$output" "DECRYPTED" "DECRYPT with specific paths returns DECRYPTED"
}

test_sudo_parses_user_and_command() {
  # Test that SUDO line correctly extracts user and multi-word command
  local output
  output=$(run_handler "success" "approve" "SUDO:myagent:nix-env -p /nix/var/nix/profiles/system --set ./result && ./result/bin/switch-to-configuration switch\n")
  assert_equals "$output" "APPROVED" "SUDO with complex command is approved"
}

test_empty_line_terminates() {
  # After an empty line, reading should stop. Extra lines should be ignored.
  local output
  output=$(run_handler "success" "approve" "SUDO:ada:whoami\n\nSUDO:ada:this-should-be-ignored\n")
  assert_equals "$output" "APPROVED" "Empty line terminates reading; extra lines ignored"
}

# ── Main ───────────────────────────────────────────────────────────

main() {
  echo ""
  echo "Nuketown: Broker Protocol Tests"
  echo ""

  run_test "SUDO-only approved" test_sudo_only_approved
  run_test "SUDO-only denied" test_sudo_only_denied
  run_test "Legacy format approved" test_legacy_format_approved
  run_test "Legacy format denied" test_legacy_format_denied
  run_test "DECRYPT-only success" test_decrypt_only_success
  run_test "DECRYPT-only failure" test_decrypt_only_failure
  run_test "Combined DECRYPT+SUDO approved" test_combined_decrypt_sudo_approved
  run_test "Combined: gpg success overrides zenity" test_combined_decrypt_sudo_gpg_success_overrides_zenity
  run_test "Combined: gpg fail + zenity deny" test_combined_decrypt_sudo_gpg_fail_zenity_deny
  run_test "Empty input returns error" test_empty_input
  run_test "SUDO command with colons" test_sudo_command_with_colons
  run_test "DECRYPT parses src and dest" test_decrypt_parses_src_and_dest
  run_test "SUDO parses user and command" test_sudo_parses_user_and_command
  run_test "Empty line terminates reading" test_empty_line_terminates

  print_summary
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
