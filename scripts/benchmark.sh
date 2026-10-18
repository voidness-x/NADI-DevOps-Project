#!/usr/bin/env python3
import urllib.request
import ssl
import time
import concurrent.futures
import sys

URL = "https://127.0.0.1:8000/api/health"
RATE = 25       # Requests per second
DURATION = 30   # Seconds to run
TOTAL_TARGET = RATE * DURATION

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

success = 0
failed = 0
latencies = []

def send_request(_):
    global success, failed
    t0 = time.time()
    try:
        with urllib.request.urlopen(URL, context=ctx, timeout=3) as resp:
            elapsed = (time.time() - t0) * 1000
            if resp.status == 200:
                return (True, elapsed)
    except Exception:
        pass
    return (False, 0.0)

print("=" * 60)
print(f"  NADI GYM — ZERO-DOWNTIME EMPIRICAL BENCHMARK")
print(f"  Target: {URL} | Rate: {RATE} req/s | Duration: {DURATION}s")
print("=" * 60)
print("Executing benchmark stream...")

start_time = time.time()
with concurrent.futures.ThreadPoolExecutor(max_workers=RATE) as executor:
    for second in range(DURATION):
        sec_start = time.time()
        results = list(executor.map(send_request, range(RATE)))
        for ok, lat in results:
            if ok:
                success += 1
                latencies.append(lat)
            else:
                failed += 1
        elapsed_sec = time.time() - sec_start
        if elapsed_sec < 1.0:
            time.sleep(1.0 - elapsed_sec)

total_time = time.time() - start_time
total_requests = success + failed
availability = (success / total_requests * 100) if total_requests else 0.0

latencies.sort()
def get_p(pct):
    if not latencies: return 0.0
    idx = int(len(latencies) * (pct / 100.0))
    idx = min(idx, len(latencies) - 1)
    return latencies[idx]

p50 = get_p(50)
p90 = get_p(90)
p95 = get_p(95)
p99 = get_p(99)

print("\n" + "=" * 60)
print("                    BENCHMARK RESULTS REPORT")
print("=" * 60)
print(f"Total Requests Dispatched:   {total_requests}")
print(f"Successful Requests (200 OK): {success} ({availability:.2f}%)")
print(f"Failed / Dropped Requests:   {failed}")
print(f"Total Benchmark Duration:    {total_time:.2f} seconds")
print("-" * 60)
print("LATENCY DISTRIBUTION:")
print(f"  Median (p50):              {p50:.2f} ms")
print(f"  90th Percentile (p90):     {p90:.2f} ms")
print(f"  95th Percentile (p95):     {p95:.2f} ms")
print(f"  99th Percentile (p99):     {p99:.2f} ms")
print("-" * 60)
if failed == 0 and availability == 100.0:
    print("STATUS: ZERO DOWNTIME CONFIRMED (100% AVAILABILITY)")
else:
    print(f"STATUS: WARNING - {failed} REQUESTS DROPPED")
print("=" * 60)

sys.exit(0 if failed == 0 else 1)
