#!/usr/bin/env bats
# =====================================================================
# FORGE-AI :: interface contract for every shell script
# =====================================================================
# Not what the scripts do -- that needs a KVM host -- but the contract
# every one of them must honour so an operator can discover and trust
# them: --help works, unknown options are rejected, and nothing
# destructive runs without confirmation.
# =====================================================================

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export REPO_ROOT
}

all_scripts() {
    find "$REPO_ROOT/bootstrap" "$REPO_ROOT/scripts" -maxdepth 1 -name '*.sh' -type f | sort
}

@test "every script has a bash shebang" {
    while read -r script; do
        head -1 "$script" | grep -q '^#!/usr/bin/env bash' || {
            echo "$script does not start with #!/usr/bin/env bash"
            return 1
        }
    done < <(all_scripts)
}

@test "every script sets -Eeuo pipefail" {
    while read -r script; do
        grep -q '^set -Eeuo pipefail' "$script" || {
            echo "$script does not set -Eeuo pipefail"
            return 1
        }
    done < <(all_scripts)
}

@test "every script installs the error trap" {
    while read -r script; do
        grep -q 'forge_enable_traps' "$script" || {
            echo "$script does not call forge_enable_traps"
            return 1
        }
    done < <(all_scripts)
}

@test "every script is executable" {
    while read -r script; do
        [ -x "$script" ] || { echo "$script is not executable"; return 1; }
    done < <(all_scripts)
}

@test "every script responds to --help with exit 0" {
    while read -r script; do
        run timeout 20 bash "$script" --help
        [ "$status" -eq 0 ] || { echo "$script --help exited $status"; return 1; }
        [ -n "$output" ] || { echo "$script --help printed nothing"; return 1; }
    done < <(all_scripts)
}

@test "every script rejects an unknown option" {
    while read -r script; do
        run timeout 20 bash "$script" --definitely-not-an-option
        [ "$status" -ne 0 ] || {
            echo "$script accepted an unknown option"
            return 1
        }
    done < <(all_scripts)
}

@test "destroy.sh does not proceed without confirmation" {
    run bash -c "cd '$REPO_ROOT' && echo '' | timeout 30 ./scripts/destroy.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not confirmed"* || "$output" == *"terminal"* ]]
}

@test "destroy.sh rejects --volumes without --all" {
    run timeout 20 bash "$REPO_ROOT/scripts/destroy.sh" --volumes
    [ "$status" -ne 0 ]
    [[ "$output" == *"only makes sense with --all"* ]]
}

@test "no script contains a curl-pipe-shell installation" {
    # Downloading and executing in one step means nothing can be
    # inspected or verified between the two.
    #
    # Comments are stripped before matching: a script that documents why
    # it does NOT use curl | sh would otherwise fail its own check.
    while read -r script; do
        if sed 's/#.*$//' "$script" \
           | grep -Eq 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh([[:space:]]|$)'; then
            echo "$script contains a curl-pipe-shell pattern"
            return 1
        fi
    done < <(all_scripts)
}

@test "no script disables TLS verification unconditionally" {
    # --insecure is permitted only where a named variable controls it,
    # so the choice is visible in the code and reportable to the
    # operator. A bare --insecure is not.
    while read -r script; do
        if sed 's/#.*$//' "$script" | grep -Eq 'curl.*(--insecure|[[:space:]]-k[[:space:]])'; then
            grep -Eq 'CURL_TLS_OPTIONS|VALIDATE_TLS|validate-tls' "$script" || {
                echo "$script disables TLS verification with no named control"
                return 1
            }
        fi
    done < <(all_scripts)
}
