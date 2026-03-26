#!/bin/bash
# Scenario C: Burst from Zero
# Run AFTER Lambda has been idle for 20+ minutes
#
# Uses oha for all targets. SigV4 signing is applied to Lambda URLs.
# All targets are hit simultaneously (background processes).
#
# Usage: ./scenario-c.sh <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>
# Example: ./scenario-c.sh https://abc.lambda-url.us-east-1.on.aws https://def.lambda-url.us-east-1.on.aws http://alb-dns-name http://1.2.3.4:8080

set -euo pipefail

LAMBDA_ZIP_URL="${1:?Usage: $0 <lambda-zip-url> <lambda-container-url> <fargate-alb-url> <ec2-url>}"
LAMBDA_CONTAINER_URL="${2:?}"
FARGATE_URL="${3:?}"
EC2_URL="${4:?}"
source "$(dirname "$0")/oha-helpers.sh"

echo "=== Scenario C: Burst from Zero ==="
echo "Ensure Lambda has been idle for 20+ minutes."
echo ""
echo "NOTE: Lambda concurrency is capped at 10 (AWS Academy limit: max 10 concurrent"
echo "Lambda execution environments). Fargate/EC2 use c=50."
echo ""
echo "Launching burst to ALL targets simultaneously..."
echo ""

# Lambda: 200 requests at c=10 (Academy limit: max 10 concurrent environments)
oha_lambda -n 200 -c 10 \
    "${LAMBDA_ZIP_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-c-lambda-zip.txt" &

oha_lambda -n 200 -c 10 \
    "${LAMBDA_CONTAINER_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-c-lambda-container.txt" &

# Fargate/EC2: 200 requests at c=50 (no concurrency limit)
oha_http -n 200 -c 50 \
    "${FARGATE_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-c-fargate.txt" &

oha_http -n 200 -c 50 \
    "${EC2_URL}/search" 2>&1 | tee "${RESULTS_DIR}/scenario-c-ec2.txt" &

wait
echo ""
echo "=== Scenario C complete. Results in ${RESULTS_DIR} ==="
