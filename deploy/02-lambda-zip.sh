#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 2: Lambda Zip Deployment ==="

# --- Build NumPy Lambda Layer ---
echo "Building NumPy Lambda layer..."
LAYER_DIR="${DEPLOY_DIR}/lambda-layer"
rm -f "${LAYER_DIR}/numpy-layer.zip"

docker run --rm -v "${LAYER_DIR}:/out" python:3.12-slim \
    bash -c "apt-get update -qq && apt-get install -y -qq zip >/dev/null 2>&1 && pip install --quiet numpy==1.26.4 -t /tmp/python && cd /tmp && zip -qr /out/numpy-layer.zip python"

echo "Publishing Lambda layer..."
LAYER_ARN=$(aws lambda publish-layer-version \
    --layer-name numpy-py312 \
    --zip-file "fileb://${LAYER_DIR}/numpy-layer.zip" \
    --compatible-runtimes python3.12 \
    --region "$AWS_REGION" \
    --query 'LayerVersionArn' --output text)
echo "Layer ARN: ${LAYER_ARN}"

# --- Package Lambda function ---
echo "Packaging Lambda zip..."
ZIPFILE="/tmp/lsc-knn-zip.zip"
rm -f "$ZIPFILE"
cd "$WORKLOAD_DIR"
zip -j "$ZIPFILE" handler.py app.py generate_dataset.py

# --- Create or update Lambda function ---
echo "Creating Lambda function (zip)..."
if aws lambda get-function --function-name "$LAMBDA_ZIP_NAME" --region "$AWS_REGION" &>/dev/null; then
    echo "Function exists, updating code..."
    aws lambda update-function-code \
        --function-name "$LAMBDA_ZIP_NAME" \
        --zip-file "fileb://${ZIPFILE}" \
        --region "$AWS_REGION" --output text --query 'FunctionArn'
    sleep 5
    aws lambda update-function-configuration \
        --function-name "$LAMBDA_ZIP_NAME" \
        --layers "$LAYER_ARN" \
        --memory-size "$LAMBDA_MEMORY" \
        --timeout "$LAMBDA_TIMEOUT" \
        --tracing-config Mode=Active \
        --region "$AWS_REGION" --output text --query 'FunctionArn'
else
    aws lambda create-function \
        --function-name "$LAMBDA_ZIP_NAME" \
        --runtime python3.12 \
        --handler handler.lambda_handler \
        --role "$LAB_ROLE_ARN" \
        --zip-file "fileb://${ZIPFILE}" \
        --timeout "$LAMBDA_TIMEOUT" \
        --memory-size "$LAMBDA_MEMORY" \
        --layers "$LAYER_ARN" \
        --tracing-config Mode=Active \
        --region "$AWS_REGION" --output text --query 'FunctionArn'
fi

# Wait for function to be active
echo "Waiting for function to become active..."
aws lambda wait function-active-v2 --function-name "$LAMBDA_ZIP_NAME" --region "$AWS_REGION"

# --- Create Function URL ---
echo "Creating Function URL..."
FUNC_URL=$(aws lambda get-function-url-config \
    --function-name "$LAMBDA_ZIP_NAME" \
    --region "$AWS_REGION" \
    --query 'FunctionUrl' --output text 2>/dev/null || true)

if [ -z "$FUNC_URL" ] || [ "$FUNC_URL" = "None" ]; then
    FUNC_URL=$(aws lambda create-function-url-config \
        --function-name "$LAMBDA_ZIP_NAME" \
        --auth-type AWS_IAM \
        --region "$AWS_REGION" \
        --query 'FunctionUrl' --output text)

    aws lambda add-permission \
        --function-name "$LAMBDA_ZIP_NAME" \
        --statement-id FunctionURLInvoke \
        --action lambda:InvokeFunctionUrl \
        --principal "*" \
        --function-url-auth-type AWS_IAM \
        --region "$AWS_REGION" || true
fi

echo "=== Lambda Zip done. Function URL: ${FUNC_URL} ==="
