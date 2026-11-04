#!/usr/bin/env bash
set -euo pipefail

GATES_FILE=".gates.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [[ ! -f "$GATES_FILE" ]]; then
    echo "FAIL: $GATES_FILE not found in $(pwd)" >&2
    exit 1
fi

run_gate() {
    local key="$1" cmd="$2" rc=0
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
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" == *:* ]]; then
        key="${line%%:*}"
        cmd="$(trim "${line#*:}")"
    else
        key="$line"
        cmd=""
    fi

    [[ "$key" == "stack" ]] && continue

    if [[ -z "$cmd" ]]; then
        echo "$key: FAIL (empty command)"
        failed=1
        continue
    fi

    run_gate "$key" "$cmd" || failed=1
done < "$GATES_FILE"

if [[ $failed -eq 0 ]]; then
    echo "gates: PASS (all)"
    exit 0
fi
echo "gates: FAIL (see above)"
exit 1
