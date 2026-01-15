#!/bin/bash

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Check for required binaries (fzf is optional)
check_prerequisites aws kind

# Determine which stack to tear down
# Priority: 1) CLI argument, 2) Interactive fzf selection
if [ -n "$1" ]; then
    suffix="$1"
    echo "Using suffix from command line: $suffix"
elif suffix=$(select_stack_interactive); then
    echo "Selected stack with suffix: $suffix"
else
    echo "No deployed stacks found or selection cancelled."
    echo "Provide a suffix as an argument: ./full-taredown.sh <suffix>"
    exit 1
fi

get_resource_names "$suffix"

# Set stack directory
STACK_DIR="$HOME/.kind-irsa/$suffix"

echo ""
echo "Starting teardown with suffix: $suffix"
echo "This will delete the following resources:"
echo "  - Kind cluster: irsa-$suffix"
echo "  - IAM Role: $ROLE_NAME"
echo "  - OIDC Provider: $ISSUER_HOSTPATH"
echo "  - S3 Bucket: $DISCOVERY_BUCKET"
echo "  - S3 Bucket: $TARGET_BUCKET"
echo "  - Stack directory: $STACK_DIR"
echo ""

# Delete Kind cluster
echo "Deleting Kind cluster..."
kind delete cluster --name irsa-$suffix

# Detach IAM policy from role
echo "Detaching IAM policy from role..."
aws iam detach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || echo "Policy already detached or role doesn't exist"

# Delete IAM role
echo "Deleting IAM role..."
aws iam delete-role --role-name $ROLE_NAME 2>/dev/null || echo "Role already deleted or doesn't exist"

# Delete OIDC provider
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$ISSUER_HOSTPATH"
echo "Deleting OIDC provider..."
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $PROVIDER_ARN 2>/dev/null || echo "OIDC provider already deleted or doesn't exist"

# Delete target S3 bucket and contents
echo "Deleting target bucket: $TARGET_BUCKET..."
aws s3 rm s3://$TARGET_BUCKET --recursive 2>/dev/null || echo "Bucket already empty or doesn't exist"
aws s3api delete-bucket --bucket $TARGET_BUCKET --region $AWS_DEFAULT_REGION 2>/dev/null || echo "Target bucket already deleted or doesn't exist"

# Delete discovery S3 bucket and contents
echo "Deleting discovery bucket: $DISCOVERY_BUCKET..."
aws s3 rm s3://$DISCOVERY_BUCKET --recursive 2>/dev/null || echo "Bucket already empty or doesn't exist"
aws s3api delete-bucket --bucket $DISCOVERY_BUCKET --region $AWS_DEFAULT_REGION 2>/dev/null || echo "Discovery bucket already deleted or doesn't exist"

# Clean up stack directory
echo "Cleaning up stack directory..."
if [ -d "$STACK_DIR" ]; then
    rm -rf "$STACK_DIR"
    echo "Removed: $STACK_DIR"
else
    echo "Stack directory not found: $STACK_DIR"
fi

echo ""
echo "Teardown complete!"