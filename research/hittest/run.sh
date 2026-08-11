#!/bin/bash
# Harness: for each click method, launch a FRESH Target, push it to the
# background (Finder frontmost), run the controller method, and record whether
# the button actuated. Fresh relaunch per method keeps the matrix uncontaminated
# (a method that makes the window key must not help the next one).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP=/tmp/poltergeist-hittest
INFO="$TMP/info.txt"
LABEL="$TMP/label.txt"
EVENTS="$TMP/events.txt"

METHODS=(${@:-baseline fields sl both activate_both front_both psn})

kill_target() { pkill -f "hittest/Target.app/Contents/MacOS/Target" 2>/dev/null; sleep 0.4; }

launch_target() {
    rm -f "$INFO" "$LABEL" "$EVENTS"
    open "$DIR/Target.app"
    for i in $(seq 1 40); do [ -f "$INFO" ] && break; sleep 0.1; done
    sleep 0.3
}

background_target() {
    # Bring Finder to the front so Target is NOT frontmost (the real use case).
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
    sleep 0.5
}

echo "=========================================================="
for M in "${METHODS[@]}"; do
    kill_target
    launch_target
    if [ ! -f "$INFO" ]; then echo "[$M] ERROR: target did not start"; continue; fi
    read -r INFOLINE < "$INFO"
    PID=$(echo "$INFOLINE" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
    WID=$(echo "$INFOLINE" | sed -n 's/.*windowNumber=\([0-9]*\).*/\1/p')
    CG=$(echo "$INFOLINE"  | sed -n 's/.*button_cg_center=\([0-9.]*,[0-9.]*\).*/\1/p')
    OFF=$(echo "$INFOLINE" | sed -n 's/.*button_win_offset=\([0-9.]*,[0-9.]*\).*/\1/p')
    GX=${CG%,*}; GY=${CG#*,}
    WX=${OFF%,*}; WY=${OFF#*,}

    background_target
    # snapshot events log size to attribute only THIS method's events
    ELINES_BEFORE=$( [ -f "$EVENTS" ] && wc -l < "$EVENTS" || echo 0 )

    "$DIR/controller.app/Contents/MacOS/controller" "$PID" "$WID" \
        --cg "$GX" "$GY" --winlocal "$WX" "$WY" --method "$M" --tag "$M" 2>&1 \
        | grep -E "RESULT|activateWithoutRaise" | sed "s/^/[$M] /"

    # Show the windowNumber(s) the target saw for mouse events from this method.
    if [ -f "$EVENTS" ]; then
        WINS=$(tail -n +$((ELINES_BEFORE+1)) "$EVENTS" | grep -oE 'win=-?[0-9]+' | sort | uniq -c | tr '\n' ' ')
        echo "[$M] target-saw-mouse-events: ${WINS:-<none>}"
    fi
    echo "----------------------------------------------------------"
done
kill_target
echo "done."
