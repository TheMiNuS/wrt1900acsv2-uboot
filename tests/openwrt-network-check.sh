#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# BusyBox-compatible diagnostics for OpenWrt.

set -u
peer="${1:-192.168.1.100}"

echo '### BOARD'
ubus call system board 2>/dev/null || true

echo '### NETWORK CONFIGURATION'
uci show network 2>/dev/null || true

echo '### LINKS AND ADDRESSES'
ip link
ip addr

echo '### MAC / STATE / CARRIER / MASTER'
for iface in eth0 br-lan lan1 lan2 lan3 lan4 wan; do
    [ -d "/sys/class/net/$iface" ] || continue
    echo "[$iface]"
    for field in address operstate carrier; do
        [ -r "/sys/class/net/$iface/$field" ] && \
            echo "$field=$(cat "/sys/class/net/$iface/$field")"
    done
    printf 'master='
    readlink "/sys/class/net/$iface/master" 2>/dev/null || echo '-'
done

stats() {
    for iface in eth0 br-lan lan1 lan2 lan3 lan4 wan; do
        [ -d "/sys/class/net/$iface" ] || continue
        printf '%-8s ' "$iface"
        for stat in rx_packets tx_packets rx_bytes tx_bytes rx_errors tx_errors rx_dropped tx_dropped; do
            printf '%s=%s ' "$stat" "$(cat "/sys/class/net/$iface/statistics/$stat")"
        done
        echo
    done
}

echo '### COUNTERS BEFORE'
stats
echo '### NEIGHBOURS BEFORE'
ip neigh show
ping -c 3 "$peer" || true
echo '### NEIGHBOURS AFTER'
ip neigh show
echo '### COUNTERS AFTER'
stats
echo '### DSA / MDIO / MVNETA LOGS'
dmesg | grep -Ei 'mv88|dsa|mdio|mvneta' || true
