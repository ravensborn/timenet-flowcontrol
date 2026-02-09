
#!/bin/bash

# Flow Meter Control Script
# Opens valve, monitors flow until 40L reached, then closes valve and resets meter

TARGET_LITERS=0.200
LOCKFILE="/var/run/flow_control.lock"

# Function to cleanup on exit
cleanup() {
    rm -f "$LOCKFILE"
}

# Check if script is already running
if [ -f "$LOCKFILE" ]; then
    # Check if the process is still actually running
    OLD_PID=$(cat "$LOCKFILE")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Error: Script is already running (PID: $OLD_PID)"
        exit 1
    else
        # Stale lock file, remove it
        echo "Removing stale lock file..."
        rm -f "$LOCKFILE"
    fi
fi

# Create lock file with current PID
echo $$ > "$LOCKFILE"

# Ensure lock file is removed on exit (normal, error, or interrupt)
trap cleanup EXIT INT TERM

# Function to read flow meter and calculate total liters
read_flow_meter() {
    response=$(ubus call modbus_client.rpc serial.test '{"id":1,"timeout":1,"function":3,"first_reg":3,"reg_count":"4","data_type":"16bit_int_hi_first","no_brackets":0,"serial_type":"/dev/rs485","baudrate":9600,"databits":8,"stopbits":1,"parity":"none","flowcontrol":"none"}' 2>/dev/null)

    # Extract the result array from response
    result=$(echo "$response" | grep -o '"result": *"\[[^]]*\]"' | sed 's/"result": *"\[//;s/\]"//')

    # Parse the 4 values (T1, T2, T3, T4)
    T1=$(echo "$result" | cut -d',' -f1 | tr -d ' ')
    T2=$(echo "$result" | cut -d',' -f2 | tr -d ' ')
    T3=$(echo "$result" | cut -d',' -f3 | tr -d ' ')
    T4=$(echo "$result" | cut -d',' -f4 | tr -d ' ')

    # Calculate total: T1 * 100000000 + T2 * 10000 + T3 + T4/1000
    # Using awk for floating point arithmetic
    total=$(awk "BEGIN {printf \"%.3f\", $T1 * 100000000 + $T2 * 10000 + $T3 + $T4 / 1000}")

    echo "$total"
}

# Function to open valve (9000 = fully open)
open_valve() {
    ubus call modbus_client.rpc serial.test '{"id":2,"timeout":1,"function":16,"first_reg":2,"reg_count":"9000","data_type":"16bit_int_hi_first","no_brackets":0,"serial_type":"/dev/rs485","baudrate":9600,"databits":8,"stopbits":1,"parity":"none","flowcontrol":"none"}' >/dev/null 2>&1
}

# Function to close valve (0000 = closed)
close_valve() {
    ubus call modbus_client.rpc serial.test '{"id":2,"timeout":1,"function":16,"first_reg":2,"reg_count":"0000","data_type":"16bit_int_hi_first","no_brackets":0,"serial_type":"/dev/rs485","baudrate":9600,"databits":8,"stopbits":1,"parity":"none","flowcontrol":"none"}' >/dev/null 2>&1
}

# Function to reset flow meter
reset_flow_meter() {
    ubus call modbus_client.rpc serial.test '{"id":1,"timeout":1,"function":6,"first_reg":3,"reg_count":"0000","data_type":"16bit_int_hi_first","no_brackets":0,"serial_type":"/dev/rs485","baudrate":9600,"databits":8,"stopbits":1,"parity":"none","flowcontrol":"none"}' >/dev/null 2>&1
}

# Main script
echo "Starting flow control (PID: $$)..."
echo "Target: ${TARGET_LITERS} liters"


# Extra sleep to prevent reading two sensors at the same time when script is ran on loop
sleep 2

# Open the valve
echo "Opening valve..."
open_valve
sleep 1

# Monitor flow until target reached
echo "Monitoring flow..."
while true; do
    current_flow=$(read_flow_meter)
    echo "Current flow: ${current_flow} L"

    # Compare using awk (floating point comparison)
    reached=$(awk "BEGIN {print ($current_flow >= $TARGET_LITERS) ? 1 : 0}")

    if [ "$reached" -eq 1 ]; then
        echo "Target reached! Flow: ${current_flow} L"
        break
    fi

    sleep 1
done

# Close the valve
echo "Closing valve..."
close_valve
sleep 4

# Reset the flow meter
echo "Resetting flow meter..."
reset_flow_meter

echo "Done!"
exit 
