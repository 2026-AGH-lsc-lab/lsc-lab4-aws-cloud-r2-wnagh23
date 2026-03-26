#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 5: EC2 Application Instance (t3.small) ==="

# --- Get default VPC ---
VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")

# --- Security Group ---
echo "Creating app security group..."
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${APP_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$APP_SG_NAME" \
        --description "EC2 app for k-NN lab" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp --port 8080 --cidr 0.0.0.0/0 \
        --region "$AWS_REGION"
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 \
        --region "$AWS_REGION"
fi
echo "Security Group: ${SG_ID}"

# --- Find AMI ---
echo "Finding latest Amazon Linux 2023 AMI..."
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "$AWS_REGION")
echo "AMI: ${AMI_ID}"

# --- Use pre-created LabInstanceProfile ---
# AWS Academy Learner Lab pre-creates LabInstanceProfile with LabRole attached.
# Do NOT attempt to create instance profiles — IAM is extremely limited in Learner Lab.
echo "Checking for LabInstanceProfile..."
if aws iam get-instance-profile --instance-profile-name LabInstanceProfile &>/dev/null; then
    INSTANCE_PROFILE_NAME="LabInstanceProfile"
else
    echo "ERROR: LabInstanceProfile not found. This is pre-created by AWS Academy."
    echo "If you are not using AWS Academy, create it manually:"
    echo "  aws iam create-instance-profile --instance-profile-name LabInstanceProfile"
    echo "  aws iam add-role-to-instance-profile --instance-profile-name LabInstanceProfile --role-name LabRole"
    exit 1
fi
echo "Instance Profile: ${INSTANCE_PROFILE_NAME}"

# --- User data script ---
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
dnf install -y docker
systemctl enable docker && systemctl start docker
USERDATA
)
# Append ECR login and docker run with actual values
USER_DATA="${USER_DATA}
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
docker pull ${ECR_URI}:latest
docker run -d -p 8080:8080 -e MODE=server --restart always --name knn-app ${ECR_URI}:latest
"

# --- Check for existing instance ---
EXISTING_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=lsc-knn-app" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text \
    --region "$AWS_REGION" 2>/dev/null)

if [ "$EXISTING_ID" != "None" ] && [ -n "$EXISTING_ID" ]; then
    echo "Instance already running: ${EXISTING_ID}"
    INSTANCE_ID="$EXISTING_ID"
else
    echo "Launching EC2 instance..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type t3.small \
        --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
        --security-group-ids "$SG_ID" \
        --user-data "$USER_DATA" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=lsc-knn-app}]" \
        --query 'Instances[0].InstanceId' --output text \
        --region "$AWS_REGION")
fi
echo "Instance ID: ${INSTANCE_ID}"

# --- Wait for instance to be running ---
echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text \
    --region "$AWS_REGION")

echo "=== EC2 App done. Public IP: ${PUBLIC_IP} ==="
echo "URL: http://${PUBLIC_IP}:8080"
echo "NOTE: Wait ~2 minutes for Docker to pull and start the container."
echo "Test with: curl -X POST -H 'Content-Type: application/json' -d @loadtest/query.json http://${PUBLIC_IP}:8080/search"
