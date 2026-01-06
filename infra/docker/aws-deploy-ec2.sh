#!/bin/bash

###############################################################################
# Golem Docker Compose Deployment Script - EC2 Single Instance
#
# This script automates the deployment of Golem using Docker Compose on a 
# single AWS EC2 instance.
#
# Prerequisites:
# - AWS CLI configured with credentials
# - SSH key pair created in AWS
# - jq installed (brew install jq)
#
# Usage:
#   ./aws-deploy-ec2.sh --key-name your-key-name --region us-east-1
###############################################################################

set -e  # Exit on error
set -o pipefail  # Exit on pipe failure

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="t3.small"
KEY_NAME=""
DEFAULT_KEY_NAME="golem-docker-compose-key"
INSTANCE_NAME="golem-intest"
SECURITY_GROUP_NAME="golem-docker-sg"
VOLUME_SIZE=100
IAM_ROLE_NAME="golem-ec2-ssm-role"
INSTANCE_PROFILE_NAME="golem-ec2-ssm-profile"
PARAMETER_STORE_PREFIX="/golem/docker"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --key-name)
      KEY_NAME="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --instance-type)
      INSTANCE_TYPE="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Optional:"
      echo "  --key-name          AWS EC2 key pair name for SSH access"
      echo "                      (default: $DEFAULT_KEY_NAME, will be created if not exists)"
      echo "  --region            AWS region (default: us-east-1)"
      echo "  --instance-type     EC2 instance type (default: t3.small)"
      echo "  --help              Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Use default key name if not provided
if [ -z "$KEY_NAME" ]; then
  KEY_NAME="$DEFAULT_KEY_NAME"
fi

# Functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
  log_info "Checking prerequisites..."
  
  # Check AWS CLI
  if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found. Please install it first."
    exit 1
  fi
  
  # Check jq
  if ! command -v jq &> /dev/null; then
    log_error "jq not found. Please install it: brew install jq"
    exit 1
  fi
  
  # Verify AWS credentials
  if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured. Run 'aws configure' first."
    exit 1
  fi
  
  log_success "Prerequisites check passed"
}

# Create IAM role and instance profile for SSM access
create_iam_role() {
  log_info "Creating IAM role for Parameter Store access..."
  
  # Get AWS account ID for the policy
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  
  # Check if role already exists
  if aws iam get-role --role-name "$IAM_ROLE_NAME" &> /dev/null; then
    log_info "IAM role '$IAM_ROLE_NAME' already exists, updating policies..."
  else
    # Create the trust policy document
    TRUST_POLICY='{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }'
    
    # Create the role
    aws iam create-role \
      --role-name "$IAM_ROLE_NAME" \
      --assume-role-policy-document "$TRUST_POLICY" \
      --description "Role for Golem EC2 to access SSM Parameter Store" \
      > /dev/null
    
    log_success "IAM role created: $IAM_ROLE_NAME"
  fi
  
  # Always attach/update policies (idempotent operations)
  log_info "Ensuring IAM policies are attached..."
  
  # Attach SSM policy for Parameter Store access (idempotent)
  aws iam attach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
    2>/dev/null || log_info "AmazonSSMManagedInstanceCore policy already attached"
  
  # Create inline policy for Parameter Store access with proper variable substitution
  cat > /tmp/parameter-store-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": [
        "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter${PARAMETER_STORE_PREFIX}",
        "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_ID}:parameter${PARAMETER_STORE_PREFIX}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:DescribeParameters"
      ],
      "Resource": "*"
    }
  ]
}
EOF
  
  aws iam put-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-name "GolemParameterStoreAccess" \
    --policy-document "file:///tmp/parameter-store-policy.json"
  
  log_success "IAM policies attached/updated"
  
  # Verify the policy was created successfully
  log_info "Verifying policy attachment..."
  if aws iam get-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-name "GolemParameterStoreAccess" \
    > /dev/null 2>&1; then
    log_success "Policy verified successfully"
  else
    log_error "Failed to verify policy attachment"
    exit 1
  fi
  
  # Check if instance profile exists
  if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &> /dev/null; then
    log_info "Instance profile '$INSTANCE_PROFILE_NAME' already exists"
  else
    # Create instance profile
    aws iam create-instance-profile \
      --instance-profile-name "$INSTANCE_PROFILE_NAME" \
      > /dev/null
    
    # Add role to instance profile
    aws iam add-role-to-instance-profile \
      --instance-profile-name "$INSTANCE_PROFILE_NAME" \
      --role-name "$IAM_ROLE_NAME"
    
    log_success "Instance profile created: $INSTANCE_PROFILE_NAME"
  fi
  
  # Wait for IAM changes to propagate (important for new policies or updates)
  log_info "Waiting for IAM changes to propagate (15 seconds)..."
  sleep 15
  log_success "IAM role and policies ready"
}

# Generate a cryptographically secure random token
# 32 random bytes, base64url-encoded without padding
generate_token() {
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
}

# Store static tokens and configuration in Parameter Store
store_parameters() {
  log_info "Storing static tokens and configuration in AWS Parameter Store..."

  # Generate secure random tokens
  log_info "Generating cryptographically secure random tokens..."
  ADMIN_TOKEN_VALUE=$(generate_token)
  MARKETING_TOKEN_VALUE=$(generate_token)
  CORS_ORIGIN_REGEX_VALUE=".*"  # Placeholder - will be updated with actual IP after instance launch
  
  # Store ADMIN_TOKEN
  PARAM_NAME="${PARAMETER_STORE_PREFIX}/ADMIN_TOKEN"
  if aws ssm put-parameter \
    --name "$PARAM_NAME" \
    --value "$ADMIN_TOKEN_VALUE" \
    --type "String" \
    --overwrite \
    --region "$AWS_REGION" \
    > /dev/null 2>&1; then
    log_success "Stored ADMIN_TOKEN with generated value"
  else
    log_warning "Could not store ADMIN_TOKEN"
  fi
  
  # Store MARKETING_TOKEN
  PARAM_NAME="${PARAMETER_STORE_PREFIX}/MARKETING_TOKEN"
  if aws ssm put-parameter \
    --name "$PARAM_NAME" \
    --value "$MARKETING_TOKEN_VALUE" \
    --type "String" \
    --overwrite \
    --region "$AWS_REGION" \
    > /dev/null 2>&1; then
    log_success "Stored MARKETING_TOKEN with generated value"
  else
    log_warning "Could not store MARKETING_TOKEN"
  fi
  
  # Store CORS_ORIGIN_REGEX
  PARAM_NAME="${PARAMETER_STORE_PREFIX}/CORS_ORIGIN_REGEX"
  if aws ssm put-parameter \
    --name "$PARAM_NAME" \
    --value "$CORS_ORIGIN_REGEX_VALUE" \
    --type "String" \
    --overwrite \
    --region "$AWS_REGION" \
    > /dev/null 2>&1; then
    log_success "Stored CORS_ORIGIN_REGEX (default: allow all)"
  else
    log_warning "Could not store CORS_ORIGIN_REGEX"
  fi
  
  log_success "Stored 3 configuration parameters in Parameter Store at: $PARAMETER_STORE_PREFIX"
  log_info "Generated tokens are cryptographically secure (32 random bytes, base64url-encoded)"
}

# Ensure SSH key pair exists
ensure_key_pair() {
  log_info "Checking SSH key pair..."
  
  # Check if key exists in AWS
  if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" &> /dev/null; then
    log_info "Key pair '$KEY_NAME' exists in AWS"
  else
    log_info "Creating new key pair '$KEY_NAME'..."
    aws ec2 create-key-pair \
      --key-name "$KEY_NAME" \
      --query 'KeyMaterial' \
      --output text \
      --region "$AWS_REGION" > ~/.ssh/${KEY_NAME}.pem

    chmod 400 ~/.ssh/${KEY_NAME}.pem
    log_success "Key pair created and saved to ~/.ssh/${KEY_NAME}.pem"
  fi

  # Check if local key file exists
  if [ ! -f ~/.ssh/${KEY_NAME}.pem ]; then
    log_error "Key file ~/.ssh/${KEY_NAME}.pem not found. Cannot connect to instance."
    log_error "If you have the key elsewhere, copy it to ~/.ssh/${KEY_NAME}.pem"
    exit 1
  fi

  log_success "SSH key pair ready"
}

# Create security group
create_security_group() {
  log_info "Setting up security group..."

  # Get default VPC
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text \
    --region "$AWS_REGION")

  if [ "$VPC_ID" = "None" ]; then
    log_error "No default VPC found. Please create a VPC first."
    exit 1
  fi

  # Check if security group exists
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" \
    --output text \
    --region "$AWS_REGION" 2>/dev/null)

  if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
    log_info "Security group '$SECURITY_GROUP_NAME' already exists"
  else
    # Create security group
    SG_ID=$(aws ec2 create-security-group \
      --group-name "$SECURITY_GROUP_NAME" \
      --description "Security group for Golem Docker deployment" \
      --vpc-id "$VPC_ID" \
      --query 'GroupId' \
      --output text \
      --region "$AWS_REGION")

    log_success "Security group created: $SG_ID"

    # Add SSH rule
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port 22 \
      --cidr 0.0.0.0/0 \
      --region "$AWS_REGION" \
      > /dev/null

    # Add Golem ports
    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port 9881 \
      --cidr 0.0.0.0/0 \
      --region "$AWS_REGION" \
      > /dev/null

    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port 9006 \
      --cidr 0.0.0.0/0 \
      --region "$AWS_REGION" \
      > /dev/null

    log_success "Security group rules added"
  fi

  SECURITY_GROUP_ID="$SG_ID"
}

# Launch EC2 instance
launch_instance() {
  log_info "Launching EC2 instance..."

  # Get latest Amazon Linux 2023 AMI
  AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text \
    --region "$AWS_REGION")

  log_info "Using Amazon Linux 2023 AMI: $AMI_ID"

  # Get instance profile ARN
  INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --query 'InstanceProfile.Arn' \
    --output text)

  # Launch instance
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --region "$AWS_REGION" \
    --query 'Instances[0].InstanceId' \
    --output text)

  log_success "Instance launched: $INSTANCE_ID"

  # Wait for instance to be running
  log_info "Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

  # Get instance details
  INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0]')

  PUBLIC_IP=$(echo "$INSTANCE_INFO" | jq -r '.PublicIpAddress')
  PUBLIC_HOSTNAME=$(echo "$INSTANCE_INFO" | jq -r '.PublicDnsName')

  log_success "Instance is running"
  log_info "Public IP: $PUBLIC_IP"
  log_info "Public DNS: $PUBLIC_HOSTNAME"

  # Wait for SSH to be available
  log_info "Waiting for SSH to be available..."
  RETRY_COUNT=0
  MAX_RETRIES=30
  while ! ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@${PUBLIC_IP} 'echo SSH ready' &> /dev/null; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
      log_error "SSH not available after $MAX_RETRIES attempts"
      exit 1
    fi
    echo -n "."
    sleep 10
  done
  echo ""

  log_success "SSH is available"
}

# Update CORS origin in Parameter Store with actual instance IP
update_cors_origin() {
  log_info "Updating CORS_ORIGIN_REGEX with instance hostname..."

  CORS_ORIGIN_REGEX_VALUE="http://${PUBLIC_HOSTNAME}:9881"

  PARAM_NAME="${PARAMETER_STORE_PREFIX}/CORS_ORIGIN_REGEX"
  if aws ssm put-parameter \
    --name "$PARAM_NAME" \
    --value "$CORS_ORIGIN_REGEX_VALUE" \
    --type "String" \
    --overwrite \
    --region "$AWS_REGION" \
    > /dev/null 2>&1; then
    log_success "Updated CORS_ORIGIN_REGEX to: $CORS_ORIGIN_REGEX_VALUE"
  else
    log_warning "Could not update CORS_ORIGIN_REGEX"
  fi
}

# Install Docker on instance
install_docker() {
  log_info "Installing Docker on EC2 instance..."

  ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ec2-user@${PUBLIC_IP} 'bash -s' << 'ENDSSH'
    set -e

    # Update package list
    sudo yum update -y

    # Install Docker (Amazon Linux 2023 has docker in the standard repos)
    sudo yum install -y docker

    # Add user to docker group
    sudo usermod -aG docker ec2-user

    # Start and enable Docker
    sudo systemctl enable docker
    sudo systemctl start docker

    # Install Docker Compose (standalone binary)
    echo "Installing Docker Compose..."
    DOCKER_COMPOSE_VERSION="v2.24.5"
    sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    docker-compose --version
ENDSSH

  log_success "Docker and Docker Compose installed successfully"
}

# Deploy Golem
deploy_golem() {
  log_info "Deploying Golem services..."

  # Create golem directory
  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP} "mkdir -p ~/golem"

  # Copy docker-compose, nginx config, and .env file
  log_info "Copying configuration files..."
  scp -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no \
    docker-compose.yaml \
    .env \
    nginx.conf.template \
    ec2-user@${PUBLIC_IP}:~/golem/

  # Setup Docker Compose services with Parameter Store integration
  log_info "Setting up Golem services with Parameter Store integration..."
  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP} \
    "export PARAMETER_STORE_PREFIX='${PARAMETER_STORE_PREFIX}' AWS_REGION='${AWS_REGION}' && bash -s" << 'EOF'
    cd ~/golem

    # AWS CLI is already installed on Amazon Linux
    echo "AWS CLI is pre-installed on Amazon Linux"
    
    # Verify AWS CLI installation
    if ! command -v aws &> /dev/null; then
      echo "ERROR: AWS CLI not found"
      exit 1
    fi

    echo "AWS CLI version:"
    aws --version

    # Create script to fetch configuration from Parameter Store
    cat > fetch-config.sh << 'FETCHSCRIPT'
#!/bin/bash
set -e

PARAMETER_STORE_PREFIX="${PARAMETER_STORE_PREFIX:-/golem/docker}"

# Auto-detect AWS region from EC2 instance metadata
echo "Detecting AWS region from EC2 instance metadata..."
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
AWS_REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/region)

if [ -z "$AWS_REGION" ]; then
    echo "WARNING: Could not detect region from instance metadata, falling back to environment variable"
    AWS_REGION="${AWS_REGION:-us-east-1}"
fi

ENV_FILE="/home/ec2-user/golem/.env.parameter-store"

# AWS CLI is built-in on Amazon Linux
AWS_CLI="/usr/bin/aws"

echo "Using AWS CLI at: $AWS_CLI"
echo "AWS CLI version: $($AWS_CLI --version)"
echo "Fetching configuration from AWS Parameter Store..."
echo "Parameter Store path: ${PARAMETER_STORE_PREFIX}"
echo "AWS Region: ${AWS_REGION}"

# Test AWS CLI access
if ! $AWS_CLI sts get-caller-identity --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "ERROR: AWS CLI authentication failed. Check IAM role permissions."
    exit 1
fi

# Fetch parameters and export them as environment variables
echo "Fetching parameters from Parameter Store..."
$AWS_CLI ssm get-parameters-by-path --path "$PARAMETER_STORE_PREFIX" --with-decryption --recursive \
    --query "Parameters[*].[Name,Value]" --output text --region "$AWS_REGION" | \
    while read -r name value; do
        # Convert /golem/docker/ADMIN_TOKEN → ADMIN_TOKEN
        env_name=$(echo "${name#$PARAMETER_STORE_PREFIX}" | tr '[:lower:]/' '[:upper:]_' | sed 's/^_//')
        printf -v "$env_name" '%s' "$value"
        export "$env_name"
        echo "Exported: $env_name"
    done

# Also write to env file for Docker Compose
> "$ENV_FILE"  # Clear/create the file
echo "Writing parameters to $ENV_FILE..."
$AWS_CLI ssm get-parameters-by-path --path "$PARAMETER_STORE_PREFIX" --with-decryption --recursive \
    --query "Parameters[*].[Name,Value]" --output text --region "$AWS_REGION" | \
    while IFS=$'\t' read -r name value; do
        # Extract key from parameter name (remove prefix and leading slash)
        key=$(echo "${name#$PARAMETER_STORE_PREFIX}" | sed 's|^/||')
        # Write to env file (ensure proper escaping)
        echo "${key}=${value}" >> "$ENV_FILE"
        echo "  Wrote: ${key}=<hidden>"
    done

echo "Contents of $ENV_FILE:"
cat "$ENV_FILE"

if [ ! -s "$ENV_FILE" ]; then
    echo "WARNING: No parameters found in Parameter Store at ${PARAMETER_STORE_PREFIX}"
    echo "Available parameters:"
    $AWS_CLI ssm describe-parameters --region "$AWS_REGION" | head -20
    exit 1
else
    echo "Configuration successfully written to $ENV_FILE"
    echo "Found $(wc -l < "$ENV_FILE") parameters"
fi
FETCHSCRIPT

    chmod +x fetch-config.sh

    # Create wrapper script that fetches config and starts Docker Compose
    cat > start-golem.sh << 'STARTSCRIPT'
#!/bin/bash
set -e

cd /home/ec2-user/golem

echo "=== Starting Golem deployment ==="

# Fetch configuration from Parameter Store (writes to .env.parameter-store)
echo "Step 1: Fetching configuration from AWS Parameter Store..."
./fetch-config.sh

if [ ! -f .env.parameter-store ]; then
    echo "ERROR: Failed to fetch configuration from Parameter Store"
    exit 1
fi

# Merge .env.parameter-store with .env file for Docker Compose
echo "Step 2: Creating combined env file..."
if [ -f .env ]; then
    cat .env > .env.combined
    # Ensure .env ends with a newline before appending
    [ -n "$(tail -c1 .env.combined)" ] && echo "" >> .env.combined
else
    touch .env.combined
fi
cat .env.parameter-store >> .env.combined
echo "Combined env file created"

# Start Docker Compose with env vars exported inline
echo "Step 3: Starting Docker Compose with environment variables..."
# Filter out comments and empty lines, then pass to env command
env $(grep -v '^#' .env.combined | grep -v '^$' | xargs) docker-compose up -d

echo "=== Golem services started successfully ==="
echo "Checking service status..."
docker-compose ps
STARTSCRIPT

    chmod +x start-golem.sh

    # Create systemd service for Golem with Parameter Store integration
    sudo tee /etc/systemd/system/golem.service > /dev/null << SERVICEUNIT
[Unit]
Description=Golem Docker Compose Application
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/ec2-user/golem
Environment="PARAMETER_STORE_PREFIX=${PARAMETER_STORE_PREFIX}"
Environment="AWS_REGION=${AWS_REGION}"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Start Golem (fetches config from Parameter Store and starts containers)
ExecStart=/bin/bash /home/ec2-user/golem/start-golem.sh

# Stop Docker Compose services
ExecStop=/bin/bash -c 'cd /home/ec2-user/golem && /usr/local/bin/docker-compose down'

# Restart services when they fail
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
SERVICEUNIT

    # Initial startup - fetch config and start services
    echo "Performing initial deployment..."
    export PARAMETER_STORE_PREFIX="${PARAMETER_STORE_PREFIX}"
    export AWS_REGION="${AWS_REGION}"

    # Test fetch-config.sh
    echo "Testing Parameter Store access..."
    ./fetch-config.sh

    if [ ! -f .env.parameter-store ] || [ ! -s .env.parameter-store ]; then
        echo "ERROR: Failed to fetch parameters from Parameter Store"
        echo "Checking AWS credentials..."
        aws sts get-caller-identity
        exit 1
    fi

    # Export Parameter Store values as environment variables for docker compose
    if [ -f .env.parameter-store ]; then
        echo "Exporting Parameter Store configuration..."
        set -a
        source .env.parameter-store
        set +a
    fi

    # Create combined env file
    if [ -f .env ]; then
        cat .env > .env.combined
        # Ensure .env ends with a newline before appending
        [ -n "$(tail -c1 .env.combined)" ] && echo "" >> .env.combined
    else
        touch .env.combined
    fi

    if [ -f .env.parameter-store ]; then
        cat .env.parameter-store >> .env.combined
    fi

    # Export all variables before pulling/starting
    set -a
    source .env.combined
    set +a

    # Pull Docker images
    echo "Pulling Docker images..."
    docker-compose --env-file .env.combined pull

    # Start services initially
    echo "Starting services for the first time..."
    docker-compose --env-file .env.combined up -d

    # Enable and start the systemd service
    sudo systemctl daemon-reload
    sudo systemctl enable golem.service

    echo "Golem service installed and started with Parameter Store integration"
    echo ""
    echo "Service status:"
    sudo systemctl status golem.service --no-pager || true
    echo ""
    echo "Container status:"
    docker-compose ps
EOF
  
  log_success "Golem services deployed with automatic Parameter Store configuration sync"
}

# Verify deployment
verify_deployment() {
  log_info "Verifying deployment..."
  
  # Wait a bit for services to start
  sleep 30
  
  # Check if services are running
  log_info "Checking service status..."
  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP} "cd ~/golem && docker-compose ps"
  
  # Test endpoints
  log_info "Testing endpoints..."
  
  if curl -s -f "http://${PUBLIC_IP}:9881/v1/components" > /dev/null; then
    log_success "Router endpoint is responding"
  else
    log_warning "Router endpoint not responding yet. It may need more time to start."
  fi
  
  log_success "Deployment verification complete"
}

# Print summary
print_summary() {
  echo ""
  echo "=========================================="
  echo -e "${GREEN}Deployment Complete!${NC}"
  echo "=========================================="
  echo ""
  echo "Instance Details:"
  echo "  Instance ID:     $INSTANCE_ID"
  echo "  Public IP:       $PUBLIC_IP"
  echo "  Public Hostname: $PUBLIC_HOSTNAME"
  echo "  Region:          $AWS_REGION"
  echo ""
  echo "AWS Resources:"
  echo "  IAM Role:        $IAM_ROLE_NAME"
  echo "  Instance Profile: $INSTANCE_PROFILE_NAME"
  echo "  Parameter Store: $PARAMETER_STORE_PREFIX"
  echo ""
  echo "Golem Endpoints:"
  echo "  Router:       http://${PUBLIC_IP}:9881"
  echo "  Worker API:   http://${PUBLIC_IP}:9006"
  echo ""
  echo "Configuration:"
  echo "  Configuration from Parameter Store (fetched on each service start):"
  echo "    - ADMIN_TOKEN"
  echo "    - MARKETING_TOKEN"
  echo "    - CORS_ORIGIN_REGEX"
  echo "  Other configuration is in the .env file"
  echo ""
  echo "  A systemd service 'golem.service' has been installed that:"
  echo "    - Fetches configuration from Parameter Store before starting"
  echo "    - Automatically starts on boot"
  echo "    - Restarts on failure"
  echo ""
  echo "Manage Parameter Store Configuration:"
  echo "  View all parameters:"
  echo "    aws ssm get-parameters-by-path --path $PARAMETER_STORE_PREFIX --region $AWS_REGION"
  echo ""
  echo "  Update ADMIN_TOKEN:"
  echo "    aws ssm put-parameter --name $PARAMETER_STORE_PREFIX/ADMIN_TOKEN --value <YOUR_TOKEN> --overwrite --region $AWS_REGION"
  echo ""
  echo "  Update MARKETING_TOKEN:"
  echo "    aws ssm put-parameter --name $PARAMETER_STORE_PREFIX/MARKETING_TOKEN --value <YOUR_TOKEN> --overwrite --region $AWS_REGION"
  echo ""
  echo "  Update CORS_ORIGIN_REGEX:"
  echo "    aws ssm put-parameter --name $PARAMETER_STORE_PREFIX/CORS_ORIGIN_REGEX --value <YOUR_REGEX> --overwrite --region $AWS_REGION"
  echo ""
  echo "SSH to instance:"
  echo "  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
  echo ""
  echo "View logs:"
  echo "  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
  echo "  cd ~/golem && docker-compose logs -f"
  echo ""
  echo "Restart services:"
  echo "  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
  echo "  sudo systemctl restart golem.service"
  echo ""
  echo "Stop services:"
  echo "  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
  echo "  cd ~/golem && docker-compose down"
  echo ""
  echo "To deploy your components:"
  echo "  export GOLEM_ROUTER_URL=\"http://${PUBLIC_IP}:9881\""
  echo "  export GOLEM_WORKER_URL=\"http://${PUBLIC_IP}:9006\""
  echo "  # Then use golem CLI to deploy your components"
  echo ""
  echo "Clean up when done:"
  echo "  ./aws-cleanup-ec2.sh --instance-id ${INSTANCE_ID} --region ${AWS_REGION}"
  echo ""
}

# Main execution
main() {
  echo ""
  echo "=========================================="
  echo "Golem Docker Compose EC2 Deployment"
  echo "=========================================="
  echo ""
  
  check_prerequisites
  create_iam_role
  store_parameters
  ensure_key_pair
  create_security_group
  launch_instance
  update_cors_origin
  install_docker
  deploy_golem
  verify_deployment
  print_summary
}

# Run main function
main
