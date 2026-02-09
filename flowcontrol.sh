#!/bin/bash

###########################################
# Flow Meter Predictive Control Script
###########################################

TARGET_LITERS=0.200
VALVE_CLOSE_TIME=1        # Seconds it takes valve to fully close
CHECK_INTERVAL=0.5        # Flow meter polling interval (seconds)
LOCKFILE="/var/run/flow_control.lock"

###########################################
# Cleanup
###########################################
cleanup() {
    rm -f "$LOCKFILE"
}
trap cleanup EXIT INT TERM

###########################################
# Prevent Multiple Instances
###########################################
if [ -f "$LOCKFILE" ]; then
    OLD_PID=$(cat "$LOCKFILE")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Error: Script already running (PID: $OLD_PID)"
        exit 1
    else
        echo "Removing stale lock file..."
        rm -f "$LOCKFILE"
    fi
fi

echo $$ > "$LOCKFILE"

###########################################
# Flow Meter Read Function
###########################################
read_flow_meter() {
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
# Valve Control Functions
###########################################
open_valve() {
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
# Reset Flow Meter
###########################################
reset_flow_meter() {
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
# Main Logic
###########################################

echo "-------------------------------------"
echo "Flow Control Started (PID: $$)"
echo "Target Volume: ${TARGET_LITERS} L"
echo "-------------------------------------"

sleep 2   # Prevent bus collision

echo "Opening valve..."
open_valve

sleep 2   # Allow stable flow

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
        echo "Predictive cutoff reached — closing valve..."
        close_valve
        break
    fi

    previous_flow=$current_flow
    previous_time=$current_time

    sleep $CHECK_INTERVAL
done

echo "Resetting flow meter..."
reset_flow_meter

echo "Flow Control Complete"
echo "-------------------------------------"
exit 0
