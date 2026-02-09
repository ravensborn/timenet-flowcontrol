#!/bin/bash

###########################################
# CONFIGURATION
###########################################

TARGET_LITERS=0.200          # Target volume in liters
VALVE_CLOSE_TIME=1.0         # Seconds valve needs to fully close
CHECK_INTERVAL=0.4           # Flow logic interval (can be < RS485 gap)
RS485_MIN_GAP=0.9             # Minimum seconds between RS485 calls

LOCKFILE="/var/run/flow_control.lock"

###########################################
# GLOBALS
###########################################

LAST_RS485_CALL=0

###########################################
# CLEANUP
###########################################
cleanup() {
    rm -f "$LOCKFILE"
}
trap cleanup EXIT INT TERM

###########################################
# SINGLE INSTANCE LOCK
###########################################
if [ -f "$LOCKFILE" ]; then
    OLD_PID=$(cat "$LOCKFILE")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Error: Script already running (PID $OLD_PID)"
        exit 1
    else
        echo "Removing stale lock file"
        rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$LOCKFILE"

###########################################
# RS485 BUS GUARD
###########################################
rs485_guard() {
    now=$(date +%s.%N)

    if [ "$LAST_RS485_CALL" != "0" ]; then
        elapsed=$(awk "BEGIN {print $now - $LAST_RS485_CALL}")
        need_wait=$(awk "BEGIN {print ($elapsed < $RS485_MIN_GAP) ? 1 : 0}")

        if [ "$need_wait" -eq 1 ]; then
            wait_time=$(awk "BEGIN {print $RS485_MIN_GAP - $elapsed}")
            sleep $wait_time
        fi
    fi

    LAST_RS485_CALL=$(date +%s.%N)
}

###########################################
# FLOW METER READ
###########################################
read_flow_meter() {
    rs485_guard

    response=$(ubus call modbus_client.rpc serial.test '{
        "id":1,
        "timeout":1,
        "function":3,
        "first_reg":3,
        "reg_count":"4",
        "data_type":"16bit_int_hi_first",
        "no_brackets":0,
        "serial_type":"/dev/rs485",
        "baudrate":9600,
        "databits":8,
        "stopbits":1,
        "parity":"none",
        "flowcontrol":"none"
    }' 2>/dev/null)

    result=$(echo "$response" | grep -o '"result": *"\[[^]]*\]"' | sed 's/"result": *"\[//;s/\]"//')

    T1=$(echo "$result" | cut -d',' -f1 | tr -d ' ')
    T2=$(echo "$result" | cut -d',' -f2 | tr -d ' ')
    T3=$(echo "$result" | cut -d',' -f3 | tr -d ' ')
    T4=$(echo "$result" | cut -d',' -f4 | tr -d ' ')

    awk "BEGIN {printf \"%.3f\", $T1 * 100000000 + $T2 * 10000 + $T3 + $T4 / 1000}"
}

###########################################
# VALVE CONTROL
###########################################
open_valve() {
    rs485_guard
    ubus call modbus_client.rpc serial.test '{
        "id":2,
        "timeout":1,
        "function":16,
        "first_reg":2,
        "reg_count":"9000",
        "data_type":"16bit_int_hi_first",
        "no_brackets":0,
        "serial_type":"/dev/rs485",
        "baudrate":9600,
        "databits":8,
        "stopbits":1,
        "parity":"none",
        "flowcontrol":"none"
    }' >/dev/null 2>&1
}

close_valve() {
    rs485_guard
    ubus call modbus_client.rpc serial.test '{
        "id":2,
        "timeout":1,
        "function":16,
        "first_reg":2,
        "reg_count":"0000",
        "data_type":"16bit_int_hi_first",
        "no_brackets":0,
        "serial_type":"/dev/rs485",
        "baudrate":9600,
        "databits":8,
        "stopbits":1,
        "parity":"none",
        "flowcontrol":"none"
    }' >/dev/null 2>&1
}

###########################################
# RESET FLOW METER
###########################################
reset_flow_meter() {
    rs485_guard
    ubus call modbus_client.rpc serial.test '{
        "id":1,
        "timeout":1,
        "function":6,
        "first_reg":3,
        "reg_count":"0000",
        "data_type":"16bit_int_hi_first",
        "no_brackets":0,
        "serial_type":"/dev/rs485",
        "baudrate":9600,
        "databits":8,
        "stopbits":1,
        "parity":"none",
        "flowcontrol":"none"
    }' >/dev/null 2>&1
}

###########################################
# MAIN LOGIC
###########################################

echo "--------------------------------------"
echo "Flow Control Started (PID $$)"
echo "Target: ${TARGET_LITERS} L"
echo "RS485 gap: ${RS485_MIN_GAP}s"
echo "--------------------------------------"

sleep 2   # Allow bus to settle

echo "Opening valve..."
open_valve
sleep 2   # Let flow stabilize

previous_flow=$(read_flow_meter)
previous_time=$(date +%s.%N)

echo "Monitoring flow..."

while true; do
    current_flow=$(read_flow_meter)
    current_time=$(date +%s.%N)

    delta_volume=$(awk "BEGIN {print $current_flow - $previous_flow}")
    delta_time=$(awk "BEGIN {print $current_time - $previous_time}")

    if (( $(awk "BEGIN {print ($delta_time > 0)}") )); then
        flow_rate=$(awk "BEGIN {print $delta_volume / $delta_time}")
    else
        flow_rate=0
    fi

    predicted_overshoot=$(awk "BEGIN {print $flow_rate * $VALVE_CLOSE_TIME}")
    stop_at=$(awk "BEGIN {print $TARGET_LITERS - $predicted_overshoot}")

    printf "Flow: %.3f L | Rate: %.3f L/s | StopAt: %.3f L\n" \
        "$current_flow" "$flow_rate" "$stop_at"

    reached=$(awk "BEGIN {print ($current_flow >= $stop_at) ? 1 : 0}")

    if [ "$reached" -eq 1 ]; then
        echo "Predictive cutoff reached — closing valve"
        close_valve
        break
    fi

    previous_flow=$current_flow
    previous_time=$current_time

    sleep $CHECK_INTERVAL
done

echo "Resetting flow meter..."
reset_flow_meter

echo "Done."
echo "--------------------------------------"
exit 0
