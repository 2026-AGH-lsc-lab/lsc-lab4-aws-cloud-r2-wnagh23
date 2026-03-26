#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 6: EC2 Workstation (t3.small) ==="

# --- Key Pair ---
# AWS Academy Learner Lab pre-creates the 'vockey' key pair in us-east-1.
# Use it instead of creating a new one. Download the PEM from "AWS Details" in the lab console.
VOCKEY_NAME="vockey"
if aws ec2 describe-key-pairs --key-names "$VOCKEY_NAME" --region "$AWS_REGION" &>/dev/null; then
    echo "Using pre-created key pair: ${VOCKEY_NAME}"
    echo "NOTE: Download the PEM file from 'AWS Details' in the Learner Lab console."
    echo "  Save it as ~/.ssh/labsuser.pem and run: chmod 600 ~/.ssh/labsuser.pem"
    KEY_NAME="$VOCKEY_NAME"
    KEY_FILE="${HOME}/.ssh/labsuser.pem"
else
    echo "WARNING: 'vockey' key pair not found. Creating custom key pair: ${KEY_NAME}"
    if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" &>/dev/null; then
        aws ec2 create-key-pair \
            --key-name "$KEY_NAME" \
            --query 'KeyMaterial' --output text \
            --region "$AWS_REGION" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    fi
fi

# --- Get default VPC ---
VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")

# --- Security Group ---
echo "Creating workstation security group..."
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${WS_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$WS_SG_NAME" \
        --description "EC2 workstation for k-NN lab" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 \
        --region "$AWS_REGION"
fi
echo "Security Group: ${SG_ID}"

# --- Find AMI ---
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "$AWS_REGION")

# --- Detect repo URL from the current clone ---
REPO_URL=$(git -C "$(dirname "$0")" remote get-url origin 2>/dev/null || echo "https://github.com/dice-dydakt/lsc-aws.git")
REPO_DIR=$(basename "$REPO_URL" .git)
echo "Repo to clone on workstation: ${REPO_URL}"

# --- User data ---
USER_DATA=$(cat <<USERDATA
#!/bin/bash
dnf install -y docker git python3-pip jq
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# oha load testing tool
curl -sL https://github.com/hatoo/oha/releases/latest/download/oha-linux-amd64 -o /usr/local/bin/oha
chmod +x /usr/local/bin/oha

# Clone the student's lab repo (detected from the machine running this script)
su - ec2-user -c 'git clone ${REPO_URL}'
USERDATA
)

# --- Check for existing instance ---
EXISTING_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=lsc-knn-workstation" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text \
    --region "$AWS_REGION" 2>/dev/null)

if [ "$EXISTING_ID" != "None" ] && [ -n "$EXISTING_ID" ]; then
    echo "Instance already running: ${EXISTING_ID}"
    INSTANCE_ID="$EXISTING_ID"
else
    # Use pre-created LabInstanceProfile (do NOT attempt to create — IAM is restricted)
    INSTANCE_PROFILE_NAME=""
    if aws iam get-instance-profile --instance-profile-name LabInstanceProfile &>/dev/null; then
        INSTANCE_PROFILE_NAME="LabInstanceProfile"
    else
        echo "WARNING: LabInstanceProfile not found. Workstation will not have AWS CLI access."
    fi

    echo "Launching workstation..."
    LAUNCH_ARGS=(
        --image-id "$AMI_ID"
        --instance-type t3.small
        --key-name "$KEY_NAME"
        --security-group-ids "$SG_ID"
        --user-data "$USER_DATA"
        --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3}'
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=lsc-knn-workstation}]"
        --query 'Instances[0].InstanceId' --output text
        --region "$AWS_REGION"
    )
    if [ -n "$INSTANCE_PROFILE_NAME" ]; then
        LAUNCH_ARGS+=(--iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}")
    fi

    INSTANCE_ID=$(aws ec2 run-instances "${LAUNCH_ARGS[@]}")
fi
echo "Instance ID: ${INSTANCE_ID}"

echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text \
    --region "$AWS_REGION")

echo "=== Workstation ready. Public IP: ${PUBLIC_IP} ==="
echo "SSH: ssh -i ${KEY_FILE} ec2-user@${PUBLIC_IP}"
echo "NOTE: Wait ~2 minutes for user-data to complete, then:"
echo "  ssh -i ${KEY_FILE} ec2-user@${PUBLIC_IP}"
echo "  cd ${REPO_DIR} && oha --version && docker --version"
