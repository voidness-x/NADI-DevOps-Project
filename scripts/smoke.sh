#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-8001}"
MAX_RETRIES=5
SLEEP_INTERVAL=2

echo "Running smoke test on http://${HOST}:${PORT}/..."

for ((i=1; i<=MAX_RETRIES; i++)); do
    if curl -s -f "http://${HOST}:${PORT}/" > /dev/null 2>&1; then
        echo "Smoke test PASSED on attempt ${i}."
        exit 0
    fi
    echo "Attempt ${i}/${MAX_RETRIES} failed. Retrying in ${SLEEP_INTERVAL}s..."
    sleep "${SLEEP_INTERVAL}"
done

echo "Smoke test FAILED after ${MAX_RETRIES} attempts."
exit 1
