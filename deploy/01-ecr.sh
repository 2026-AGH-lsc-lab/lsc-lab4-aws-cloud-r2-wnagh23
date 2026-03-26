#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 1: ECR Repository & Docker Image ==="

# Create ECR repository (ignore if exists)
echo "Creating ECR repository..."
aws ecr create-repository \
    --repository-name "$ECR_REPO_NAME" \
    --region "$AWS_REGION" 2>/dev/null || echo "Repository already exists."

# Docker login to ECR
echo "Logging into ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Build image
echo "Building Docker image..."
docker build -t "${ECR_REPO_NAME}:latest" "$WORKLOAD_DIR"

# Tag and push
echo "Pushing image to ECR..."
docker tag "${ECR_REPO_NAME}:latest" "${ECR_URI}:latest"
docker push "${ECR_URI}:latest"

echo "=== ECR done. Image URI: ${ECR_URI}:latest ==="
