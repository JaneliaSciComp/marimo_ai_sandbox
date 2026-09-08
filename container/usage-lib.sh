#!/usr/bin/env bash
#
# usage-lib.sh -- shared --help support. Not meant to be executed directly.
#
# print_usage_and_exit SCRIPT -- prints SCRIPT's own top-of-file comment
# block (the header every script here already carries) and exits 0. Single
# source of truth: the text `--help` shows is exactly the comment block a
# developer sees when opening the file, so the two can't drift apart.
print_usage_and_exit() {
    awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
    exit 0
}
