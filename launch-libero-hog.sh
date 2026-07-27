#!/bin/sh
# Resolve this script's own directory so it works from any checkout, user, or
# workstation instead of a hardcoded absolute path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
libero "SCRIPT:$SCRIPT_DIR/Tcl/launch.tcl" SCRIPT_ARGS:"CREATE smm-ethercat"
