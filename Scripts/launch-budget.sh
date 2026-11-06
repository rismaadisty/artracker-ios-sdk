#!/usr/bin/env bash
set -euo pipefail

mkdir -p docs/evidence

echo "========================================="
echo " ARTracker Launch Time Budget Gate"
echo " Target Budget: Phase A <= 2.0 ms"
echo "========================================="

echo "Running LaunchMetrics benchmark test..."
OUTPUT=$(swift test --filter LaunchMetricsTests/testPhaseAInitializationBudgetGate)
echo "$OUTPUT"

cat << EOF > docs/evidence/launch-metrics.txt
ARTracker Launch Metrics Gate Report
Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Toolchain: Apple Swift 6.x / macOS / iOS 15.0+

$OUTPUT

Gate Condition: Phase A p95 <= 2.0ms
Status: PASS
EOF

echo "✅ Saved launch evidence to docs/evidence/launch-metrics.txt"
