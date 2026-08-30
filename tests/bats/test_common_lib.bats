#!/usr/bin/env bats
# =====================================================================
# FORGE-AI :: tests for bootstrap/lib/common.sh
# =====================================================================
#   bats tests/bats/
#
# The helpers in common.sh are used by every script in the project, so a
# regression here breaks all of them at once. These tests exercise the
# behaviours that are easy to get subtly wrong: secret generation under
# `set -o pipefail`, file modes, and the confirmation prompt refusing to
# assume "yes" from a non-interactive shell.
# =====================================================================

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export REPO_ROOT
    # shellcheck source=/dev/null
    source "$REPO_ROOT/bootstrap/lib/common.sh"
    TEST_TEMP="$(mktemp -d)"
}

teardown() {
    [[ -n "${TEST_TEMP:-}" ]] && rm -rf "$TEST_TEMP"
}

# ---------------------------------------------------------------------
# forge_random_secret
# ---------------------------------------------------------------------

@test "forge_random_secret returns exactly the requested length" {
    for length in 8 16 32 48 64; do
        result="$(forge_random_secret "$length")"
        [ "${#result}" -eq "$length" ]
    done
}

@test "forge_random_secret survives set -o pipefail" {
    # The original implementation piped tr into `head -c N`. head closes
    # the pipe once satisfied, tr takes SIGPIPE, and pipefail turns that
    # into exit 141 -- intermittently, which is the worst kind.
    run bash -c "set -Eeuo pipefail
                 source '$REPO_ROOT/bootstrap/lib/common.sh'
                 for i in \$(seq 1 40); do forge_random_secret 32 >/dev/null; done
                 echo done"
    [ "$status" -eq 0 ]
    [ "$output" = "done" ]
}

@test "forge_random_secret produces only shell-safe characters" {
    # The value goes into .env, YAML and command lines unquoted.
    result="$(forge_random_secret 64)"
    [[ "$result" =~ ^[A-Za-z0-9]+$ ]]
}

@test "forge_random_secret does not repeat itself" {
    first="$(forge_random_secret 32)"
    second="$(forge_random_secret 32)"
    [ "$first" != "$second" ]
}

# ---------------------------------------------------------------------
# forge_write_secret_file
# ---------------------------------------------------------------------

@test "forge_write_secret_file creates a file with mode 0600" {
    target="$TEST_TEMP/secret.txt"
    forge_write_secret_file "$target" "a-secret-value"

    [ -f "$target" ]
    [ "$(stat -c '%a' "$target")" = "600" ]
    [ "$(cat "$target")" = "a-secret-value" ]
}

@test "forge_write_secret_file creates missing parent directories" {
    target="$TEST_TEMP/nested/deeply/secret.txt"
    forge_write_secret_file "$target" "value"

    [ -f "$target" ]
    [ "$(stat -c '%a' "$target")" = "600" ]
}

@test "forge_write_secret_file honours an explicit mode" {
    target="$TEST_TEMP/readable.txt"
    forge_write_secret_file "$target" "value" 0640

    [ "$(stat -c '%a' "$target")" = "640" ]
}

@test "forge_write_secret_file never leaves a world-readable window" {
    # The mode is applied to an empty file before the content is
    # written, so there is no moment at which the secret exists in a
    # readable file.
    grep -q 'install -m "\$mode" /dev/null "\$path"' "$REPO_ROOT/bootstrap/lib/common.sh"
}

# ---------------------------------------------------------------------
# confirm
# ---------------------------------------------------------------------

@test "confirm refuses to assume yes on a non-interactive stdin" {
    run bash -c "source '$REPO_ROOT/bootstrap/lib/common.sh'
                 confirm 'Proceed?' < /dev/null"
    [ "$status" -ne 0 ]
    [[ "$output" == *"stdin is not a terminal"* ]]
}

@test "confirm accepts an explicit override" {
    run bash -c "export FORGE_ASSUME_YES=1
                 source '$REPO_ROOT/bootstrap/lib/common.sh'
                 confirm 'Proceed?' < /dev/null"
    [ "$status" -eq 0 ]
}

@test "confirm with a token requires that exact token" {
    run bash -c "source '$REPO_ROOT/bootstrap/lib/common.sh'
                 echo 'WRONG' | confirm 'Destroy?' 'DESTROY-POC'"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------
# require_command
# ---------------------------------------------------------------------

@test "require_command succeeds for a present command" {
    run require_command bash
    [ "$status" -eq 0 ]
}

@test "require_command fails and prints the hint for a missing command" {
    run require_command definitely-not-a-real-command "install it with apt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"install it with apt"* ]]
}

# ---------------------------------------------------------------------
# error trap
# ---------------------------------------------------------------------

@test "the error trap reports the failing command and line" {
    run bash -c "set -Eeuo pipefail
                 export FORGE_SCRIPT_NAME=trap-test
                 source '$REPO_ROOT/bootstrap/lib/common.sh'
                 forge_enable_traps
                 false"
    [ "$status" -ne 0 ]
    [[ "$output" == *"trap-test failed"* ]]
    [[ "$output" == *"command"* ]]
    [[ "$output" == *"line"* ]]
}

@test "the error trap surfaces a hint when one is set" {
    run bash -c "set -Eeuo pipefail
                 source '$REPO_ROOT/bootstrap/lib/common.sh'
                 FORGE_ERROR_HINT='try running make bootstrap first'
                 forge_enable_traps
                 false"
    [[ "$output" == *"try running make bootstrap first"* ]]
}

# ---------------------------------------------------------------------
# Repository discovery
# ---------------------------------------------------------------------

@test "FORGE_ROOT points at the repository root" {
    [ -f "$FORGE_ROOT/config/defaults.yml" ]
    [ -d "$FORGE_ROOT/ansible" ]
}

@test "sourcing twice is harmless" {
    run bash -c "source '$REPO_ROOT/bootstrap/lib/common.sh'
                 source '$REPO_ROOT/bootstrap/lib/common.sh'
                 echo ok"
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

# ---------------------------------------------------------------------
# Configuration access
# ---------------------------------------------------------------------

@test "forge_config reads a value from the merged configuration" {
    command -v jq >/dev/null || skip "jq is not installed"
    result="$(forge_config '.provisioning_network.cidr')"
    [ "$result" = "192.168.250.0/24" ]
}

@test "forge_config returns empty rather than the string null" {
    command -v jq >/dev/null || skip "jq is not installed"
    result="$(forge_config '.no.such.key')"
    [ -z "$result" ]
}
