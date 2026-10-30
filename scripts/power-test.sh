#!/bin/bash
clear
echo "========================================"
echo "    POWER MANAGER - TEST DASHBOARD      "
echo "========================================"

# Get combined battery status (DisplayDevice aggregates all packs)
POWER_SUPPLY=$(upower -e | grep -i DisplayDevice | head -n 1)
[ -z "$POWER_SUPPLY" ] && POWER_SUPPLY=$(upower -e | grep -i battery | head -n 1)
if [ -n "$POWER_SUPPLY" ]; then
    STATE=$(upower -i $POWER_SUPPLY | grep state | awk '{print $2}')
    PERCENT=$(upower -i $POWER_SUPPLY | grep percentage | awk '{print $2}')
    echo "Battery Status: $STATE - $PERCENT"
else
    echo "Battery Status: Not Found"
fi

AC_ADAPTER=$(upower -e | grep -i "AC\|line_power" | head -n 1)
if [ -n "$AC_ADAPTER" ]; then
    AC_STATE=$(upower -i $AC_ADAPTER | grep online | awk '{print $2}')
    if [ "$AC_STATE" = "yes" ]; then
        echo "Power Source: AC (Plugged In)"
    else
        echo "Power Source: Battery"
    fi
fi

echo ""
echo "--- CURRENT ADVANCED SETTINGS ---"
CONFIG_FILE="$HOME/.config/onlyvishesh.power-manager.json"

if [ -f "$CONFIG_FILE" ]; then
    cat "$CONFIG_FILE" | jq -r '
    "Automatic Management : \(.enabled)",
    "Low Battery Threshold: \(.batteryThreshold)%",
    "",
    "[ SLEEP ON AC ]",
    "  Mins to sleep : \(.idle.ac.sleepAfterMinutes)",
    "  Action        : \(.idle.ac.afterSleep)",
    "  Hibernate after: \(.idle.ac.hibernateAfterMinutes)",
    "",
    "[ SLEEP ON BATTERY HIGH ]",
    "  Mins to sleep : \(.idle.batteryHigh.sleepAfterMinutes)",
    "  Action        : \(.idle.batteryHigh.afterSleep)",
    "  Hibernate after: \(.idle.batteryHigh.hibernateAfterMinutes)",
    "",
    "[ SLEEP ON BATTERY LOW ]",
    "  Mins to sleep : \(.idle.batteryLow.sleepAfterMinutes)",
    "  Action        : \(.idle.batteryLow.afterSleep)",
    "  Hibernate after: \(.idle.batteryLow.hibernateAfterMinutes)",
    "",
    "[ LID CLOSES ]",
    "  Ignore lid    : \(.lid.ignoreLidClose)",
    "  AC action     : \(.lid.ac.action)",
    "  Bat High      : \(.lid.batteryHigh.action)",
    "  Bat Low       : \(.lid.batteryLow.action)"
    '
else
    echo "Config file not found!"
fi

echo ""
echo "========================================"
echo "          LIVE EVENT TIMELINE           "
echo "========================================"

journalctl -f | grep --line-buffered -i -E 'IDLE:|omarchy idle|systemd-sleep|Performing sleep operation'
