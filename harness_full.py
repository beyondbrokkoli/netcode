import subprocess
import threading
import sys
import time
import re

sync_log = open("multiverse_full_sync.log", "w")
sync_lock = threading.Lock()

def monitor_output(process, p_id):
    """Reads stdout from a child process and filters key events/errors."""
    with open(f"p{p_id}_full.log", "a") as full_log:
        for line in iter(process.stdout.readline, ''):
            if not line: break
            full_log.write(line)
            full_log.flush()

            important_tags = [
                "[HEARTBEAT]", "FATAL", "Divergence",
                "[SYSTEM]", "[STUN]", "[LOBBY]", "[ICE]", "[SYNC]",
                "[ROUTING]", "[MATCHMAKER]", "[DIAGNOSTIC]",
                "error", "Exception", "luajit:"
            ]

            if any(tag in line for tag in important_tags):
                with sync_lock:
                    formatted_line = f"[P{p_id}] {line}"
                    sys.stdout.write(formatted_line)
                    sync_log.write(formatted_line)
                    sync_log.flush()

def main():
    print("========================================")
    print(" IGNITING LOCALHOST MULTIVERSE (8 NODES)")
    print("========================================")

    nodes = []

    # ==========================================
    # 1. BOOT HOST (Node 0)
    # ==========================================
    print("[HARNESS] Booting Node 0 (Host) on Port 50000...")
    host_proc = subprocess.Popen(
        ['luajit', 'main.lua'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1
    )

    host_proc.stdin.write("0\n")
    host_proc.stdin.write("H\n")
    host_proc.stdin.flush()
    nodes.append(host_proc)

    lobby_id = None
    print("[HARNESS] Waiting for Node 0 to secure a Lobby ID...")

    with open("p0_full.log", "w") as f0:
        while True:
            line = host_proc.stdout.readline()
            if not line:
                print("[HARNESS] FATAL: Host crashed before creating lobby!")
                sys.exit(1)

            f0.write(line)
            f0.flush()
            sys.stdout.write(f"[P0] {line}")

            match = re.search(r"holding room:\s*([A-Z0-9]{4})", line)
            if match:
                lobby_id = match.group(1)
                print("\n=======================================================")
                print(f"✅ LOBBY CREATED: {lobby_id}")
                print("=======================================================\n")
                break

    # Start monitoring Node 0 in the background now that lobby is found
    threading.Thread(target=monitor_output, args=(host_proc, 0), daemon=True).start()

    # ==========================================
    # 2. BOOT CLIENTS (Nodes 1 - 7)
    # ==========================================
    print(f"[HARNESS] Booting local clients (Nodes 1 to 7) into Lobby {lobby_id}...")
    for i in range(1, 8):
        time.sleep(0.2) # Stagger to prevent port-binding/file-lock collisions
        proc = subprocess.Popen(
            ['luajit', 'main.lua'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1
        )
        proc.stdin.write(f"{i}\n")
        proc.stdin.write("J\n")
        proc.stdin.write(f"{lobby_id}\n")
        proc.stdin.flush()
        nodes.append(proc)
        threading.Thread(target=monitor_output, args=(proc, i), daemon=True).start()

    print("\n[HARNESS] All 8 Nodes Booted. Awaiting lockstep quorum...\n")

    # ==========================================
    # WAIT STATE
    # ==========================================
    try:
        for node in nodes:
            node.wait()
    except KeyboardInterrupt:
        print("\n[HARNESS] Ctrl+C Detected. Terminating Multiverse.")
        for node in nodes:
            node.terminate()
        sync_log.close()
        print("[HARNESS] Clean Exit.")

if __name__ == "__main__":
    main()
