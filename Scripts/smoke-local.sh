#!/usr/bin/env bash
set -euo pipefail

BACKEND_URL="${1:-http://127.0.0.1:8080}"
APP_KEY="${2:-art_live_testkey123}"

echo "========================================="
echo " ARTracker Local Backend Smoke Test"
echo " Endpoint: ${BACKEND_URL}/api/v1/ingest"
echo "========================================="

PAYLOAD='{
  "sent_at": "2026-11-06T09:40:00.000Z",
  "sdk": { "name": "artracker-ios", "version": "0.1.0" },
  "context": {
    "environment": "development",
    "app_version": "1.0.0 (1)",
    "os_name": "iOS",
    "os_version": "15.0",
    "device_model": "iPhone15,3",
    "locale": "id_ID",
    "timezone": "Asia/Jakarta"
  },
  "items": [
    {
      "id": "itm_smoke_test_001",
      "type": "log",
      "level": "fatal",
      "name": "crash",
      "message": "EXC_BAD_ACCESS smoke test",
      "timestamp": "2026-11-06T09:40:00.000Z",
      "session_id": "ses_0123456789abcdef01234567",
      "attributes": {
        "stack_trace": "0 ARTrackerDemo 0x0000000100000000",
        "error_type": "SIGSEGV",
        "is_fatal": true
      }
    }
  ]
}'

echo "Sending smoke payload..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BACKEND_URL}/api/v1/ingest" \
  -H "Content-Type: application/json" \
  -H "X-Artracker-Key: ${APP_KEY}" \
  -d "${PAYLOAD}" || true)

echo "Received HTTP status: ${HTTP_STATUS}"
if [ "${HTTP_STATUS}" = "202" ]; then
  echo "✅ Ingest test succeeded (HTTP 202 Accepted)."
else
  echo "⚠️ Ingest returned HTTP ${HTTP_STATUS} (Ensure local artracker backend is running)."
fi

