#!/usr/bin/env bash
set -euo pipefail
umask 077
exec >>"${OOD_SESSION_ROOT}/output.log" 2>&1
trap 'status=$?; printf "%s\n" "$status" >"${OOD_SESSION_ROOT}/exit_status"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
script=$(realpath -- "/home/ondemand/${OOD_SCRIPT_PATH}")
case "$script" in
  /home/ondemand/*) ;;
  *) echo "Script escapes home"; exit 1 ;;
esac
[[ -f "$script" ]] || { echo "Not a regular script"; exit 1; }
cd /home/ondemand
timeout --signal=TERM --kill-after=30s "${OOD_SECONDS}s" bash -- "$script"
