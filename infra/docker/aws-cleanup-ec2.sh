#!/bin/bash

###############################################################################
# Golem Docker Compose EC2 Cleanup Script
#
# This script removes AWS resources created by aws-deploy-ec2.sh
#
# Usage:
#   ./aws-cleanup-ec2.sh --instance-id i-xxxx --region us-east-1
#   OR
#   ./aws-cleanup-ec2.sh --all --region us-east-1  # Clean up all Golem instances
###############################################################################

# Don't exit on error - we want to continue cleanup even if some steps fail
# set -e  # Exit on error
# set -o pipefail  # Exit on pipe failure

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_ID="golem-intest"
CLEANUP_ALL=false
SECURITY_GROUP_NAME="golem-docker-sg"
IAM_ROLE_NAME="golem-ec2-ssm-role"
INSTANCE_PROFILE_NAME="golem-ec2-ssm-profile"
PARAMETER_STORE_PREFIX="/golem/docker"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --instance-id)
      INSTANCE_ID="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --all)
      CLEANUP_ALL=true
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --instance-id       Specific instance ID to terminate"
      echo "  --all               Clean up all Golem Docker Compose instances"
      echo "  --region            AWS region (default: us-east-1)"
      echo "  --help              Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0 --instance-id i-1234567890abcdef0 --region us-east-1"
      echo "  $0 --all --region us-east-1"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Validate required parameters
if [ -z "$INSTANCE_ID" ] && [ "$CLEANUP_ALL" = false ]; then
  echo -e "${RED}Error: Either --instance-id or --all is required${NC}"
  echo "Use --help for usage information"
  exit 1
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
  
  # Verify AWS credentials
  if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured. Run 'aws configure' first."
    exit 1
  fi
  
  log_success "All prerequisites met"
}

# Find all Golem instances
find_golem_instances() {
  log_info "Finding Golem Docker Compose instances..."
  
  INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=golem-docker-compose" "Name=instance-state-name,Values=running,stopped" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' \
    --output text)
  
  if [ -z "$INSTANCES" ]; then
    log_warning "No Golem Docker Compose instances found"
    return 1
  fi
  
  echo ""
  echo "Found instances:"
  echo "$INSTANCES" | while read -r line; do
    echo "  $line"
  done
  echo ""
  
  return 0
}

# Terminate instance
terminate_instance() {
  local inst_id=$1
  
  log_info "Terminating instance: $inst_id"
  
  # Try to resolve instance name to instance ID if needed
  if [[ ! "$inst_id" =~ ^i- ]]; then
    log_info "Instance name provided, looking up instance ID..."
    local resolved_id=$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=$inst_id" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
      --region "$AWS_REGION" \
      --query 'Reservations[0].Instances[0].InstanceId' \
      --output text 2>/dev/null || echo "None")
    
    if [ "$resolved_id" = "None" ] || [ -z "$resolved_id" ]; then
      log_warning "Instance with name '$inst_id' not found or already terminated"
      return 0
    fi
    
    inst_id="$resolved_id"
    log_info "Found instance ID: $inst_id"
  fi
  
  # Check if instance exists
  if ! aws ec2 describe-instances --instance-ids "$inst_id" --region "$AWS_REGION" &> /dev/null; then
    log_warning "Instance $inst_id not found or already terminated"
    return 0
  fi
  
  # Get instance state
  STATE=$(aws ec2 describe-instances \
    --instance-ids "$inst_id" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "terminated")
  
  if [ "$STATE" = "terminated" ]; then
    log_warning "Instance $inst_id is already terminated"
    return 0
  fi
  
  # Terminate instance
  if aws ec2 terminate-instances \
    --instance-ids "$inst_id" \
    --region "$AWS_REGION" &> /dev/null; then
    log_success "Instance $inst_id termination initiated"
  else
    log_warning "Could not terminate instance $inst_id (may already be terminated)"
    return 0
  fi
  
  # Wait for termination
  log_info "Waiting for instance to terminate..."
  if aws ec2 wait instance-terminated \
    --instance-ids "$inst_id" \
    --region "$AWS_REGION" 2>/dev/null; then
    log_success "Instance $inst_id terminated"
  else
    log_warning "Timeout or error waiting for instance termination, but continuing..."
  fi
  
  return 0
}

# Clean up Parameter Store parameters
cleanup_parameters() {
  log_info "Cleaning up Parameter Store parameters..."
  
  # Get all parameters with the prefix
  PARAMS=$(aws ssm get-parameters-by-path \
    --path "$PARAMETER_STORE_PREFIX" \
    --region "$AWS_REGION" \
    --query 'Parameters[*].Name' \
    --output text 2>/dev/null || echo "")
  
  if [ -z "$PARAMS" ]; then
    log_warning "No parameters found at path: $PARAMETER_STORE_PREFIX"
    return 0
  fi
  
  # Delete each parameter
  local count=0
  for param in $PARAMS; do
    if aws ssm delete-parameter \
      --name "$param" \
      --region "$AWS_REGION" &> /dev/null; then
      count=$((count + 1))
    fi
  done
  
  log_success "Deleted $count parameters from Parameter Store"
}

# Clean up IAM instance profile
cleanup_instance_profile() {
  log_info "Cleaning up IAM instance profile..."
  
  # Check if instance profile exists
  if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &> /dev/null; then
    log_warning "Instance profile not found or already deleted"
    return 0
  fi
  
  # Remove role from instance profile
  log_info "Removing role from instance profile..."
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$IAM_ROLE_NAME" 2>/dev/null || log_warning "Role already removed from instance profile"
  
  # Delete instance profile
  log_info "Deleting instance profile: $INSTANCE_PROFILE_NAME"
  if aws iam delete-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" 2>/dev/null; then
    log_success "Instance profile deleted"
  else
    log_warning "Could not delete instance profile"
  fi
}

# Clean up IAM role
cleanup_iam_role() {
  log_info "Cleaning up IAM role..."
  
  # Check if role exists
  if ! aws iam get-role --role-name "$IAM_ROLE_NAME" &> /dev/null; then
    log_warning "IAM role not found or already deleted"
    return 0
  fi
  
  # Detach managed policies
  log_info "Detaching managed policies..."
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name "$IAM_ROLE_NAME" \
    --query 'AttachedPolicies[*].PolicyArn' \
    --output text 2>/dev/null || echo "")
  
  for policy_arn in $ATTACHED_POLICIES; do
    aws iam detach-role-policy \
      --role-name "$IAM_ROLE_NAME" \
      --policy-arn "$policy_arn" 2>/dev/null || true
  done
  
  # Delete inline policies
  log_info "Deleting inline policies..."
  INLINE_POLICIES=$(aws iam list-role-policies \
    --role-name "$IAM_ROLE_NAME" \
    --query 'PolicyNames[*]' \
    --output text 2>/dev/null || echo "")
  
  for policy_name in $INLINE_POLICIES; do
    aws iam delete-role-policy \
      --role-name "$IAM_ROLE_NAME" \
      --policy-name "$policy_name" 2>/dev/null || true
  done
  
  # Delete role
  log_info "Deleting IAM role: $IAM_ROLE_NAME"
  if aws iam delete-role --role-name "$IAM_ROLE_NAME" 2>/dev/null; then
    log_success "IAM role deleted"
  else
    log_warning "Could not delete IAM role"
  fi
}

# Clean up security group
cleanup_security_group() {
  log_info "Checking security group..."
  
  # Get security group ID
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")
  
  if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    log_warning "Security group not found or already deleted"
    return 0
  fi
  
  # Check if any instances are using this security group
  INSTANCES_USING_SG=$(aws ec2 describe-instances \
    --filters "Name=instance.group-id,Values=$SG_ID" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)
  
  if [ -n "$INSTANCES_USING_SG" ]; then
    log_warning "Security group is still in use by instances: $INSTANCES_USING_SG"
    log_warning "Skipping security group deletion"
    return 0
  fi
  
  # Delete security group
  log_info "Deleting security group: $SG_ID"
  if aws ec2 delete-security-group \
    --group-id "$SG_ID" \
    --region "$AWS_REGION" 2>/dev/null; then
    log_success "Security group deleted"
  else
    log_warning "Could not delete security group. It may still be in use or have dependencies."
  fi
}

# Confirm cleanup
confirm_cleanup() {
  local instances=$1
  
  echo ""
  echo -e "${YELLOW}WARNING: This will delete the following resources:${NC}"
  echo ""
  
  if [ "$CLEANUP_ALL" = true ]; then
    echo "Instances:"
    echo "$instances" | while read -r line; do
      echo "  - $line"
    done
  else
    echo "Instance: $INSTANCE_ID"
  fi
  
  echo ""
  echo "AWS Resources:"
  echo "  - Security group: $SECURITY_GROUP_NAME (if not in use)"
  echo "  - IAM role: $IAM_ROLE_NAME"
  echo "  - IAM instance profile: $INSTANCE_PROFILE_NAME"
  echo "  - Parameter Store parameters: $PARAMETER_STORE_PREFIX/*"
  echo ""
  
  read -p "Are you sure you want to continue? (yes/no): " -r
  echo
  
  if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log_info "Cleanup cancelled"
    exit 0
  fi
}

# Main execution
main() {
  echo ""
  echo "=========================================="
  echo "Golem Docker Compose EC2 Cleanup"
  echo "=========================================="
  echo ""
  
  check_prerequisites
  
  if [ "$CLEANUP_ALL" = true ]; then
    # Find and clean up all instances
    if find_golem_instances; then
      INSTANCE_LIST=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=golem-docker-compose" "Name=instance-state-name,Values=running,stopped" \
        --region "$AWS_REGION" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text)
      
      confirm_cleanup "$INSTANCE_LIST"
      
      for inst in $INSTANCE_LIST; do
        terminate_instance "$inst" || log_warning "Failed to terminate instance $inst, continuing..."
      done
    else
      log_info "No instances to clean up"
    fi
  else
    # Clean up specific instance
    confirm_cleanup ""
    terminate_instance "$INSTANCE_ID" || log_warning "Failed to terminate instance, continuing with other cleanup..."
  fi
  
  # Clean up AWS resources - continue even if individual steps fail
  log_info ""
  log_info "Cleaning up AWS resources..."
  cleanup_security_group || log_warning "Failed to cleanup security group, continuing..."
  cleanup_parameters || log_warning "Failed to cleanup parameters, continuing..."
  cleanup_instance_profile || log_warning "Failed to cleanup instance profile, continuing..."
  cleanup_iam_role || log_warning "Failed to cleanup IAM role, continuing..."
  
  echo ""
  echo "=========================================="
  echo -e "${GREEN}Cleanup Complete!${NC}"
  echo "=========================================="
  echo ""
  echo "Cleanup attempted for the following resources:"
  echo "  • EC2 instances"
  echo "  • Security group"
  echo "  • Parameter Store parameters"
  echo "  • IAM instance profile"
  echo "  • IAM role"
  echo ""
  log_info "Check the output above for any warnings or errors"
  echo ""
}

# Run main function
main
