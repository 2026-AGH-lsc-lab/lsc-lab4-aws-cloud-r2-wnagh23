#!/bin/bash
# Scenario A: Lambda Cold Start Characterization
# Run AFTER Lambda has been idle for 20+ minutes
#
# Uses oha with SigV4 signing for Lambda Function URLs.
# Sends 30 sequential requests (1 per second) to each Lambda variant.
#
# Usage: ./scenario-a.sh <lambda-zip-url> <lambda-container-url>
# Example: ./scenario-a.sh https://abc123.lambda-url.us-east-1.on.aws https://def456.lambda-url.us-east-1.on.aws

set -euo pipefail

LAMBDA_ZIP_URL="${1:?Usage: $0 <lambda-zip-url> <lambda-container-url>}"
LAMBDA_CONTAINER_URL="${2:?Usage: $0 <lambda-zip-url> <lambda-container-url>}"
source "$(dirname "$0")/oha-helpers.sh"

echo "=== Scenario A: Lambda Cold Start Characterization ==="
echo "Ensure Lambda has been idle for 20+ minutes before running."
echo ""

echo "--- Lambda Zip (30 sequential requests, 1/sec) ---"
oha_lambda -n 30 -c 1 --burst-delay 1s --burst-rate 1 \
    "${LAMBDA_ZIP_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-a-zip.txt"

echo ""
echo "Waiting 20 minutes before container variant (for cold start reset)..."
echo "Press Ctrl+C to skip the wait if running variants separately."
echo "Sleeping 1200s (20 min)..."
sleep 1200 || true

echo ""
echo "--- Lambda Container (30 sequential requests, 1/sec) ---"
oha_lambda -n 30 -c 1 --burst-delay 1s --burst-rate 1 \
    "${LAMBDA_CONTAINER_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-a-container.txt"

echo ""
echo "=== Scenario A complete. Results in ${RESULTS_DIR} ==="
echo ""
echo "Next: check CloudWatch for Init Duration (cold start) entries:"
echo "  aws logs filter-log-events --log-group-name /aws/lambda/lsc-knn-zip --filter-pattern 'Init Duration' --start-time \$(date -d '30 minutes ago' +%s000) --query 'events[*].message' --output text"
echo "  aws logs filter-log-events --log-group-name /aws/lambda/lsc-knn-container --filter-pattern 'Init Duration' --start-time \$(date -d '30 minutes ago' +%s000) --query 'events[*].message' --output text"
