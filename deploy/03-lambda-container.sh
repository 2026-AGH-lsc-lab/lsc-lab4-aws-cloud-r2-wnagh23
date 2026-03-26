#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 3: Lambda Container Image Deployment ==="

# Create or update Lambda function from ECR image
echo "Creating Lambda function (container)..."
if aws lambda get-function --function-name "$LAMBDA_CONTAINER_NAME" --region "$AWS_REGION" &>/dev/null; then
    echo "Function exists, updating code..."
    aws lambda update-function-code \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --image-uri "${ECR_URI}:latest" \
        --region "$AWS_REGION" --output text --query 'FunctionArn'
    sleep 5
    aws lambda update-function-configuration \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --memory-size "$LAMBDA_MEMORY" \
        --timeout "$LAMBDA_TIMEOUT" \
        --tracing-config Mode=Active \
        --region "$AWS_REGION" --output text --query 'FunctionArn'
else
    aws lambda create-function \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --package-type Image \
        --code "ImageUri=${ECR_URI}:latest" \
        --role "$LAB_ROLE_ARN" \
        --timeout "$LAMBDA_TIMEOUT" \
        --memory-size "$LAMBDA_MEMORY" \
        --tracing-config Mode=Active \
        --region "$AWS_REGION" --output text --query 'FunctionArn'
fi

# Wait for function to be active
echo "Waiting for function to become active..."
aws lambda wait function-active-v2 --function-name "$LAMBDA_CONTAINER_NAME" --region "$AWS_REGION"

# Create Function URL
echo "Creating Function URL..."
FUNC_URL=$(aws lambda get-function-url-config \
    --function-name "$LAMBDA_CONTAINER_NAME" \
    --region "$AWS_REGION" \
    --query 'FunctionUrl' --output text 2>/dev/null || true)

if [ -z "$FUNC_URL" ] || [ "$FUNC_URL" = "None" ]; then
    FUNC_URL=$(aws lambda create-function-url-config \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --auth-type AWS_IAM \
        --region "$AWS_REGION" \
        --query 'FunctionUrl' --output text)

    aws lambda add-permission \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --statement-id FunctionURLInvoke \
        --action lambda:InvokeFunctionUrl \
        --principal "*" \
        --function-url-auth-type AWS_IAM \
        --region "$AWS_REGION" || true
fi

echo "=== Lambda Container done. Function URL: ${FUNC_URL} ==="
