#!/bin/bash
set -uo pipefail  # no -e: continue on errors during cleanup
source "$(dirname "$0")/00-config.sh"

echo "=== Cleaning up all lab resources ==="

# --- Terminate EC2 instances ---
echo "Terminating EC2 instances..."
for TAG_NAME in lsc-knn-app lsc-knn-workstation; do
    IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-state-name,Values=running,pending,stopped" \
        --query 'Reservations[*].Instances[*].InstanceId' --output text \
        --region "$AWS_REGION" 2>/dev/null)
    if [ -n "$IDS" ] && [ "$IDS" != "None" ]; then
        echo "  Terminating ${TAG_NAME}: ${IDS}"
        aws ec2 terminate-instances --instance-ids $IDS --region "$AWS_REGION" --output text > /dev/null
    fi
done

# --- Delete ECS Service ---
echo "Deleting ECS service..."
aws ecs update-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service "$ECS_SERVICE_NAME" \
    --desired-count 0 \
    --region "$AWS_REGION" --output text > /dev/null 2>&1 || true

aws ecs delete-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service "$ECS_SERVICE_NAME" \
    --force \
    --region "$AWS_REGION" --output text > /dev/null 2>&1 || true

# --- Delete ALB resources ---
echo "Deleting ALB resources..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text \
    --region "$AWS_REGION" 2>/dev/null || true)

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
    # Delete listeners
    LISTENER_ARNS=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$ALB_ARN" \
        --query 'Listeners[*].ListenerArn' --output text \
        --region "$AWS_REGION" 2>/dev/null || true)
    for LARN in $LISTENER_ARNS; do
        [ "$LARN" = "None" ] && continue
        aws elbv2 delete-listener --listener-arn "$LARN" --region "$AWS_REGION" 2>/dev/null || true
    done
    # Delete ALB
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" 2>/dev/null || true
fi

# Delete target group
TG_ARN=$(aws elbv2 describe-target-groups \
    --names "$TG_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text \
    --region "$AWS_REGION" 2>/dev/null || true)
if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    echo "  Waiting for ALB to finish deleting before removing target group..."
    sleep 15
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$AWS_REGION" 2>/dev/null || true
fi

# --- Delete ECS cluster ---
echo "Deleting ECS cluster..."
aws ecs delete-cluster --cluster "$ECS_CLUSTER_NAME" --region "$AWS_REGION" --output text > /dev/null 2>&1 || true

# --- Delete Lambda functions ---
echo "Deleting Lambda functions..."
for FUNC_NAME in "$LAMBDA_ZIP_NAME" "$LAMBDA_CONTAINER_NAME"; do
    aws lambda delete-function-url-config \
        --function-name "$FUNC_NAME" --region "$AWS_REGION" 2>/dev/null || true
    aws lambda delete-function \
        --function-name "$FUNC_NAME" --region "$AWS_REGION" 2>/dev/null || true
done

# --- Delete Lambda layer versions ---
echo "Deleting Lambda layers..."
LAYER_VERSIONS=$(aws lambda list-layer-versions \
    --layer-name numpy-py312 \
    --query 'LayerVersions[*].Version' --output text \
    --region "$AWS_REGION" 2>/dev/null || true)
for VER in $LAYER_VERSIONS; do
    [ "$VER" = "None" ] && continue
    aws lambda delete-layer-version \
        --layer-name numpy-py312 --version-number "$VER" \
        --region "$AWS_REGION" 2>/dev/null || true
done

# --- Delete ECR repository ---
echo "Deleting ECR repository..."
aws ecr delete-repository \
    --repository-name "$ECR_REPO_NAME" \
    --force \
    --region "$AWS_REGION" 2>/dev/null || true

# --- Delete security groups (wait for instances to terminate) ---
echo "Waiting for instances to terminate..."
sleep 30
echo "Deleting security groups..."
for SG_NAME in lsc-knn-alb-sg lsc-knn-task-sg "$APP_SG_NAME" "$WS_SG_NAME"; do
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${SG_NAME}" \
        --query 'SecurityGroups[0].GroupId' --output text \
        --region "$AWS_REGION" 2>/dev/null || true)
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" 2>/dev/null || true
    fi
done

# --- Delete CloudWatch log groups ---
echo "Deleting log groups..."
aws logs delete-log-group --log-group-name "/ecs/${ECS_TASK_FAMILY}" --region "$AWS_REGION" 2>/dev/null || true

# --- Optionally delete instance profile ---
# Skipped by default: LabInstanceProfile may be used by the EC2 workstation.
# Uncomment if you want to remove it:
# aws iam remove-role-from-instance-profile \
#     --instance-profile-name LabInstanceProfile \
#     --role-name LabRole 2>/dev/null || true
# aws iam delete-instance-profile \
#     --instance-profile-name LabInstanceProfile 2>/dev/null || true

echo "=== Cleanup complete ==="
