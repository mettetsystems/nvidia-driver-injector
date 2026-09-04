#!/usr/bin/env bash
# Minimal shell test harness for the patch-composition tooling.
# Each tests/test-*.sh sources this, calls assert_*, and ends with finish_tests.

_tests_run=0
_tests_failed=0

assert_eq() {  # actual expected message
    _tests_run=$((_tests_run + 1))
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        _tests_failed=$((_tests_failed + 1))
        printf '  FAIL %s\n' "$3"
        printf '       expected: [%s]\n' "$2"
        printf '       actual:   [%s]\n' "$1"
    fi
}

assert_exit() {  # expected-code message -- command...
    local expected="$1" msg="$2"; shift 2
    _tests_run=$((_tests_run + 1))
    local stderr_out
    stderr_out=$( "$@" 2>&1 >/dev/null )
    local got=$?
    if [ "$got" -eq "$expected" ]; then
        printf '  ok   %s\n' "$msg"
    else
        _tests_failed=$((_tests_failed + 1))
        printf '  FAIL %s (exit %s, expected %s)\n' "$msg" "$got" "$expected"
        [ -n "$stderr_out" ] && printf '       stderr: %s\n' "$stderr_out"
    fi
}

assert_contains() {  # haystack needle message
    _tests_run=$((_tests_run + 1))
    if printf '%s' "$1" | grep -q -- "$2"; then
        printf '  ok   %s\n' "$3"
    else
        _tests_failed=$((_tests_failed + 1))
        printf '  FAIL %s\n' "$3"
        printf '       missing: [%s]\n' "$2"
    fi
}

assert_file_contains() {  # file needle message
    _tests_run=$((_tests_run + 1))
    if grep -q -- "$2" "$1"; then
        printf '  ok   %s\n' "$3"
    else
        _tests_failed=$((_tests_failed + 1))
        printf '  FAIL %s\n' "$3"
        printf '       file %s missing: [%s]\n' "$1" "$2"
    fi
}

finish_tests() {
    printf '%s: %d run, %d failed\n' "${0##*/}" "$_tests_run" "$_tests_failed"
    [ "$_tests_failed" -eq 0 ]
}
