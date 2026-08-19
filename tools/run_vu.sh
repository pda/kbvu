#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
app=$(CDPATH= cd -- "$script_dir/.." && pwd)/kbvu.app
if [ ! -d "$app" ]; then
    echo "kbvu-vu: app bundle not found at $app; run 'zig build' first" >&2
    exit 1
fi

tty_path=$(tty) || {
    echo "kbvu-vu: run-vu needs an interactive terminal" >&2
    exit 1
}

existing_pids=" $(pgrep -x kbvu-vu 2>/dev/null | tr '\n' ' ' || true)"
/usr/bin/open \
    -W -n -g \
    --stdin "$tty_path" \
    --stdout "$tty_path" \
    --stderr "$tty_path" \
    "$app" \
    --args --launched-as-app "$@" &
open_pid=$!

meter_pid=""
attempt=0
while [ "$attempt" -lt 100 ]; do
    for candidate in $(pgrep -x kbvu-vu 2>/dev/null || true); do
        case "$existing_pids" in
            *" $candidate "*) ;;
            *) meter_pid=$candidate ;;
        esac
    done
    if [ -n "$meter_pid" ]; then
        break
    fi
    if ! kill -0 "$open_pid" 2>/dev/null; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.02
done

forward_interrupt() {
    if [ -n "$meter_pid" ]; then
        kill -INT "$meter_pid" 2>/dev/null || true
    fi
}
trap forward_interrupt INT TERM HUP

set +e
wait "$open_pid"
status=$?
set -e

if [ "$status" -gt 128 ]; then
    forward_interrupt
    wait "$open_pid" 2>/dev/null || true
fi
exit "$status"
