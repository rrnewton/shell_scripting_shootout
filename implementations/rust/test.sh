#!/bin/sh
set -eu
exec rust-script --test "$(dirname "$0")/pr-plan.rs"
