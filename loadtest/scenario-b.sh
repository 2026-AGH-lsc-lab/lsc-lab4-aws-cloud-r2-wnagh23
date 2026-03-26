#!/bin/bash
# Scenario B: Warm Steady-State Throughput
# Run AFTER warming up all targets
#
# Uses oha for all targets. SigV4 signing is applied to Lambda URLs.
#
# Usage: ./scenario-b.sh <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>
# Example: ./scenario-b.sh https://abc.lambda-url.us-east-1.on.aws https://def.lambda-url.us-east-1.on.aws http://alb-dns-name http://1.2.3.4:8080

set -euo pipefail

LAMBDA_ZIP_URL="${1:?Usage: $0 <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>}"
LAMBDA_CONTAINER_URL="${2:?}"
FARGATE_URL="${3:?}"
EC2_URL="${4:?}"
source "$(dirname "$0")/oha-helpers.sh"

echo "=== Scenario B: Warm Steady-State Throughput ==="
echo ""
echo "NOTE: Lambda concurrency is capped at 10 (AWS Academy limit: max 10 concurrent"
echo "Lambda execution environments). Fargate/EC2 use c=10 and c=50."
echo ""

# --- Warm-up phase ---
# Lambda warm-up uses c=10 to stay within the 10-environment limit.
# Fargate/EC2 warm-up can use higher concurrency safely.
echo "--- Warm-up phase ---"
echo "  Warming up Lambda Zip (60 requests at c=10)..."
oha_lambda -n 60 -c 10 "${LAMBDA_ZIP_URL}/search" > /dev/null 2>&1
echo "  Warming up Lambda Container (60 requests at c=10)..."
oha_lambda -n 60 -c 10 "${LAMBDA_CONTAINER_URL}/search" > /dev/null 2>&1
echo "  Warming up Fargate (60 requests at c=50)..."
oha_http -n 60 -c 50 "${FARGATE_URL}/search" > /dev/null 2>&1
echo "  Warming up EC2 (60 requests at c=50)..."
oha_http -n 60 -c 50 "${EC2_URL}/search" > /dev/null 2>&1
echo "Warm-up complete."
echo ""

# --- Lambda targets (c=5 and c=10 only — Academy limit) ---
for VARIANT in zip container; do
    if [ "$VARIANT" = "zip" ]; then
        URL="${LAMBDA_ZIP_URL}"
    else
        URL="${LAMBDA_CONTAINER_URL}"
    fi
    for CONC in 5 10; do
        OUTFILE="${RESULTS_DIR}/scenario-b-lambda-${VARIANT}-c${CONC}.txt"
        echo "=== lambda-${VARIANT} | concurrency=${CONC} | 500 requests ===" | tee "$OUTFILE"
        oha_lambda -n 500 -c "$CONC" "${URL}/search" 2>&1 | tee -a "$OUTFILE"
        echo "" | tee -a "$OUTFILE"
        sleep 5
    done
done

# --- Fargate & EC2 (c=10 and c=50 — no Academy concurrency limit) ---
declare -a NAMES=("fargate" "ec2")
declare -a URLS=("${FARGATE_URL}/search" "${EC2_URL}/search")

for i in "${!URLS[@]}"; do
    for CONC in 10 50; do
        OUTFILE="${RESULTS_DIR}/scenario-b-${NAMES[$i]}-c${CONC}.txt"
        echo "=== ${NAMES[$i]} | concurrency=${CONC} | 500 requests ===" | tee "$OUTFILE"
        oha_http -n 500 -c "$CONC" "${URLS[$i]}" 2>&1 | tee -a "$OUTFILE"
        echo "" | tee -a "$OUTFILE"
        sleep 5
    done
done

echo "=== Scenario B complete. Results in ${RESULTS_DIR} ==="
