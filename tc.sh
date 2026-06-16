#!/bin/bash
echo "Clearing existing tc rules..."
sudo tc qdisc del dev lo root 2>/dev/null

echo "Applying 8-Node Split-Brain WAN Chaos..."

# 1. Create root HTB qdisc
sudo tc qdisc add dev lo root handle 1: htb default 99 r2q 1

# --- CLASS 10: "Fiber Optic" (Node 0 - Host) ---
sudo tc class add dev lo parent 1: classid 1:10 htb rate 100mbit
sudo tc qdisc add dev lo parent 1:10 handle 10: netem delay 10ms 2ms loss 0%

# --- CLASS 20: "Good Home Wi-Fi" (Nodes 1, 2) ---
sudo tc class add dev lo parent 1: classid 1:20 htb rate 50mbit
sudo tc qdisc add dev lo parent 1:20 handle 20: netem delay 40ms 10ms loss 1%

# --- CLASS 30: "Symmetric NAT / Bad 4G" (Nodes 3, 4) ---
sudo tc class add dev lo parent 1: classid 1:30 htb rate 10mbit
sudo tc qdisc add dev lo parent 1:30 handle 30: netem delay 150ms 50ms loss 5% reorder 5% 25%

# --- CLASS 40: "School Cellphone Tethering" (Nodes 5, 6, 7) ---
# 1Mbit choke. 500ms base delay + 400ms jitter with 25% correlation (Bufferbloat bursts)
# 15% packet loss + 5% duplication (forces your rollback engine to discard dupes)
sudo tc class add dev lo parent 1: classid 1:40 htb rate 1mbit
sudo tc qdisc add dev lo parent 1:40 handle 40: netem delay 500ms 400ms 25% loss 15% duplicate 5%

# --- CLASS 99: Default Fallback ---
sudo tc class add dev lo parent 1: classid 1:99 htb rate 100mbit
sudo tc qdisc add dev lo parent 1:99 handle 99: netem delay 0ms

# 2. Route traffic based on Destination UDP Port (simulating receiver's network condition)
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50000 0xffff flowid 1:10
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50001 0xffff flowid 1:20
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50002 0xffff flowid 1:20
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50003 0xffff flowid 1:30
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50004 0xffff flowid 1:30
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50005 0xffff flowid 1:40
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50006 0xffff flowid 1:40
sudo tc filter add dev lo protocol ip parent 1: prio 1 u32 match ip dport 50007 0xffff flowid 1:40

echo "✅ 8-Node Asymmetric Chaos applied successfully."
