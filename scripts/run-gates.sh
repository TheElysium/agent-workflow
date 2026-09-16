#!/usr/bin/env bash
# Runner for .gates.yml.
#
# Contract (line-based):
#   - Each non-ignored line is `key: single-line command`.
#   - Multi-line YAML values are NOT supported by this runner.
#   - Blank lines and whole-line comments (optional whitespace, then `#`)
#     are ignored.
#   - The `stack:` key is metadata and is not executed.
#   - Every other key names a command that is run with `bash -c "$cmd"`
#     from the repo root, in file order.

set -euo pipefail

GATES_FILE=".gates.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
cd "$REPO_ROOT"

if [[ ! -f "$GATES_FILE" ]]; then
    echo "FAIL: $GATES_FILE not found in $(pwd)" >&2
    exit 1
fi

run_gate() {
    local key="$1" cmd="$2"
    local rc=0
    bash -c "$cmd" </dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "$key: PASS"
    else
        echo "$key: FAIL (exit $rc)"
        return 1
    fi
}

trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

failed=0
while IFS= read -r line || [[ -n "$line" ]]; do
    # skip blank lines and whole-line comments
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    key="${line%%:*}"
    cmd="$(trim "${line#*:}")"

    [[ "$key" == "stack" ]] && continue

    if [[ -z "$cmd" ]]; then
        echo "$key: FAIL (empty command)"
        failed=1
        continue
    fi

    if ! run_gate "$key" "$cmd"; then
        failed=1
    fi
done < "$GATES_FILE"

if [[ $failed -eq 0 ]]; then
    echo "gates: PASS (all)"
    exit 0
else
    echo "gates: FAIL (see above)"
    exit 1
fi
