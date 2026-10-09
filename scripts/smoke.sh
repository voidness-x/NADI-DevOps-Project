#!/usr/bin/env bash
set -euo pipefail

SLOT="${1:-green}"

if [ "$SLOT" = "green" ]; then
    PORT="8102"
else
    PORT="8101"
fi

URL="http://127.0.0.1:${PORT}/health"
MAX_ATTEMPTS=5

echo "Running smoke test on ${URL}..."

for i in $(seq 1 $MAX_ATTEMPTS); do
    if curl -s -f "$URL" > /dev/null; then
        echo "SUCCESS: Smoke test PASSED for ${SLOT} slot on port ${PORT}."
        exit 0
    fi
    echo "Attempt $i/$MAX_ATTEMPTS failed. Retrying in 2s..."
    sleep 2
done

echo "Smoke test FAILED after $MAX_ATTEMPTS attempts."
exit 1
