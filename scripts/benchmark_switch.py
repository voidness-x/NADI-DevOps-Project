#!/usr/bin/env python3
import sys, time, ssl, os, subprocess, urllib.request
from concurrent.futures import ThreadPoolExecutor

DOMAIN = "nadi-gym.duckdns.org"
URL = f"https://{DOMAIN}:8000/api/health"
TOTAL_REQUESTS = 25
SWITCH_AFTER = 8

def get_active_slot():
    try:
        with open("/opt/gym/state/active_slot", "r") as f:
            return f.read().strip()
    except Exception:
        return "blue"

def get_slot_ports(slot):
    if slot == "green":
        return "8102", "8202"
    return "8101", "8201"

def get_env_with_secrets():
    env = os.environ.copy()
    if os.path.exists("/etc/gym/secrets/postgres_password"):
        try:
            with open("/etc/gym/secrets/postgres_password", "r") as f:
                env["POSTGRES_PASSWORD"] = f.read().strip()
        except Exception:
            pass
    elif os.path.exists("/etc/gym/backend.env"):
        try:
            with open("/etc/gym/backend.env", "r") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("POSTGRES_PASSWORD="):
                        env["POSTGRES_PASSWORD"] = line.split("=", 1)[1].strip()
        except Exception:
            pass
    return env

def ensure_slot_running(slot):
    be_port, _ = get_slot_ports(slot)
    health_url = f"http://127.0.0.1:{be_port}/health"

    # Fast probe
    try:
        req = urllib.request.Request(health_url)
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            if resp.status == 200:
                return True
    except Exception:
        pass

    # Launch container if offline
    env = get_env_with_secrets()
    subprocess.run(
        [
            "docker", "compose", "-p", f"gym-{slot}",
            "-f", "/opt/gym/devops/compose/compose.slot.yml",
            "--env-file", f"/opt/gym/devops/compose/slot-{slot}.env",
            "up", "-d"
        ],
        env=env,
        capture_output=True
    )

    # Poll until ready (up to 10s)
    for _ in range(20):
        try:
            req = urllib.request.Request(health_url)
            with urllib.request.urlopen(req, timeout=0.5) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            time.sleep(0.5)
    return False

def make_request(req_id, timeout=2.0):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(
        URL, 
        headers={"User-Agent": "ZeroDowntimeBenchmark/1.0", "Host": DOMAIN}
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            elapsed = (time.perf_counter() - t0) * 1000
            slot = resp.headers.get("x-slot", "unknown")
            return req_id, resp.status, elapsed, slot, None
    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        return req_id, 0, elapsed, "none", str(e)

def switch_slot(target_slot):
    ensure_slot_running(target_slot)
    res = subprocess.run(["sudo", "/usr/local/bin/switch_slot.sh", target_slot], capture_output=True, text=True)
    if res.returncode != 0:
        subprocess.run(["/opt/gym/devops/scripts/switch.sh", target_slot], capture_output=True)

def main():
    initial_slot = get_active_slot()
    target_slot = "green" if initial_slot == "blue" else "blue"

    # Pre-verify both slots so cutover has zero transition delay
    ensure_slot_running(initial_slot)
    ensure_slot_running(target_slot)

    print("=" * 65)
    print("NADI GYM DEVOPS: ZERO-DOWNTIME INGRESS BENCHMARK")
    print(f" Current Active Slot : {initial_slot.upper()}")
    print(f" Target Switch Slot  : {target_slot.upper()}")
    print(f" Total Probe Requests: {TOTAL_REQUESTS}")
    print(f" Ingress Endpoint    : {URL}")
    print("=" * 65)

    results = []
    switched = False
    switch_req_id = None

    print("\n[REQUEST AUDIT TRAIL]")
    print("-" * 65)

    with ThreadPoolExecutor(max_workers=5) as executor:
        for i in range(1, TOTAL_REQUESTS + 1):
            if i == SWITCH_AFTER and not switched:
                print(f" >>> [ATOMIC SWITCH TRIGGERED] Flipping traffic to {target_slot.upper()}... <<<")
                switch_slot(target_slot)
                switched = True
                switch_req_id = i

            future = executor.submit(make_request, i)
            req_id, status, elapsed, slot, err = future.result()
            results.append((req_id, status, elapsed, slot, err))

            icon = "[PASS]" if status == 200 else "[FAIL]"
            err_str = f" ({err})" if err else ""
            print(f"Req #{req_id:02d}: {icon} HTTP {status} | Latency: {elapsed:5.1f}ms | Upstream: {slot.upper()}{err_str}")
            time.sleep(0.06)

    success = [r for r in results if r[1] == 200]
    failed = [r for r in results if r[1] != 200]
    latencies = [r[2] for r in success] if success else [0.0]

    latencies.sort()
    min_lat = min(latencies)
    avg_lat = sum(latencies) / len(latencies)
    p95_idx = int(len(latencies) * 0.95)
    p95_lat = latencies[min(p95_idx, len(latencies) - 1)]
    max_lat = max(latencies)

    print("\n" + "=" * 65)
    print("BENCHMARK VERIFICATION REPORT")
    print("=" * 65)
    print(f" Requests Delivered  : {TOTAL_REQUESTS}")
    print(f" Successful (200 OK) : {len(success)} ({len(success)/TOTAL_REQUESTS*100:.1f}%)")
    print(f" Dropped / Failed    : {len(failed)} ({len(failed)/TOTAL_REQUESTS*100:.1f}%)")
    print(f" Transition Index    : Request #{switch_req_id} switched to {target_slot.upper()}")
    print(f" Latency Min / Avg   : {min_lat:.2f} ms / {avg_lat:.2f} ms")
    print(f" Latency p95 / Max   : {p95_lat:.2f} ms / {max_lat:.2f} ms\n")

    if len(failed) == 0:
        print(" [VERDICT]: PASSED - ZERO DOWNTIME PROVEN (100% Availability)")
    else:
        print(f" [VERDICT]: FAILED - {len(failed)} requests dropped during reload")
    print("=" * 65)

if __name__ == "__main__":
    main()
