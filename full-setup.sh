# Pre-reqs: Have creds for an AWS account, have kubectl, aws-cli, jq, go and kind installed.

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Check for required binaries
check_prerequisites kubectl aws jq go kind ssh-keygen openssl uuidgen

# Generate unique suffix for this stack
# Optionally provide a seed phrase as first argument for reproducible/named stacks
if [ -n "$1" ]; then
    input_string="$1"
    echo "Using provided stack identifier: $input_string"
else
    input_string=$(uuidgen)
    echo "Generated new stack identifier: $input_string"
fi
suffix=$(generate_suffix "$input_string")

# Create stack directory structure
STACK_DIR="$HOME/.kind-irsa/$suffix"
mkdir -p "$STACK_DIR"

# Generate keys for k8s configuration
rm -rf "$STACK_DIR/keys"
mkdir -p "$STACK_DIR/keys"
mkdir -p "$STACK_DIR/aws"
mkdir -p "$STACK_DIR/echoer"

# create S3 Bucket
export DISCOVERY_BUCKET="aws-irsa-oidc-discovery-$suffix"

aws s3api create-bucket --bucket $DISCOVERY_BUCKET --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION

export HOSTNAME=s3-$AWS_DEFAULT_REGION.amazonaws.com
export ISSUER_HOSTPATH=$HOSTNAME/$DISCOVERY_BUCKET

aws s3api put-public-access-block --bucket $DISCOVERY_BUCKET --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# poor man's templating using sed. note the use of ; as a delimiter to avoid clashing with characters in the templating files.
sed -e "s;DISCOVERY_BUCKET;${DISCOVERY_BUCKET};g" templates/aws/s3-readonly-policy.template.json >"$STACK_DIR/aws/s3-readonly-policy.json"
aws s3api put-bucket-policy --bucket $DISCOVERY_BUCKET --policy file://"$STACK_DIR/aws/s3-readonly-policy.json"

# Generate the keypair
PRIV_KEY="$STACK_DIR/keys/oidc-issuer.key"
PUB_KEY="$STACK_DIR/keys/oidc-issuer.key.pub"
PKCS_KEY="$STACK_DIR/keys/oidc-issuer.pub"

# Generate a key pair
ssh-keygen -t rsa -b 2048 -f $PRIV_KEY -m pem -N ""

# convert the SSH pubkey to PKCS8
ssh-keygen -e -m PKCS8 -f $PUB_KEY >$PKCS_KEY

# Use the PKCS_KEY to generate the JWKS key set for the JWKS endpoint of the Discovery Bucket
go run -C keys-generator main.go -key "$PKCS_KEY" | jq >"$STACK_DIR/aws/keys.json"

# Create and place discovery.json and keys.json in the discovery-bucket
sed -e "s;ISSUER_HOSTPATH;${ISSUER_HOSTPATH};g" templates/aws/discovery.template.json >"$STACK_DIR/aws/discovery.json"
aws s3 cp "$STACK_DIR/aws/discovery.json" s3://$DISCOVERY_BUCKET/.well-known/openid-configuration
aws s3 cp "$STACK_DIR/aws/keys.json" s3://$DISCOVERY_BUCKET/keys.json

echo "The service-account-issuer as below:"
echo "https://$ISSUER_HOSTPATH"

# Create OIDC identity provider
export CA_THUMBPRINT=$(openssl s_client -connect s3-$AWS_DEFAULT_REGION.amazonaws.com:443 -servername s3-$AWS_DEFAULT_REGION.amazonaws.com -showcerts </dev/null 2>/dev/null | openssl x509 -in /dev/stdin -sha1 -noout -fingerprint | cut -d '=' -f 2 | tr -d ':')

aws iam create-open-id-connect-provider \
  --url https://$ISSUER_HOSTPATH \
  --thumbprint-list $CA_THUMBPRINT \
  --client-id-list sts.amazonaws.com

# Setup k8s cluster:
kind delete cluster --name irsa-$suffix

sed -e "s;SUFFIX;${suffix};g; s;PWD;${STACK_DIR};g; s;HOSTNAME;${HOSTNAME};g; s;DISCOVERY_BUCKET;${DISCOVERY_BUCKET};g" templates/kind/irsa-config.template.yaml >"$STACK_DIR/kind-irsa-config.yaml"
kind create cluster --config "$STACK_DIR/kind-irsa-config.yaml" --name irsa-$suffix
echo "Cluster has been set up. Setting up cert manager in a couple of seconds:"

# Install cert manager instead of messing with certs manually:
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.crds.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml
echo "cert-manager has been applied. Waiting for deployments to be ready..."

kubectl wait --for=condition=available --timeout=300s \
  deployment/cert-manager \
  deployment/cert-manager-cainjector \
  deployment/cert-manager-webhook \
  -n cert-manager

echo "cert-manager is ready!"

# Setup k8s webhook auth stuff up. Heavily inspired by https://github.com/aws/amazon-eks-pod-identity-webhook/tree/master/deploy
kubectl create -f pod-identity-webhook/auth.yaml
kubectl create -f pod-identity-webhook/service.yaml
kubectl create -f pod-identity-webhook/cert.yaml
kubectl create -f pod-identity-webhook/mutatingwebhook-ca-bundle.yaml

# create iam role for s3 echoer job
export ISSUER_URL="https://s3-$AWS_DEFAULT_REGION.amazonaws.com/$DISCOVERY_BUCKET"
export ISSUER_HOSTPATH=$(echo $ISSUER_URL | cut -f 3- -d'/')
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$ISSUER_HOSTPATH"
export ROLE_NAME="s3-echoer-$suffix"

echo "Creating Demo role: $ROLE_NAME"
sed -e "s;PROVIDER_ARN;${PROVIDER_ARN};g; s;ISSUER_HOSTPATH;${ISSUER_HOSTPATH};g" templates/aws/irp-trust-policy.template.json >"$STACK_DIR/aws/irp-trust-policy.json"
aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document file://"$STACK_DIR/aws/irp-trust-policy.json"

aws iam attach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# create service account for s3 echoer job and attach the iam role
export S3_ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text)

# deploy s3 echoer job into k8s cluster
export TARGET_BUCKET="output-bucket-$ROLE_NAME"

echo "Creating demo target-bucket: $TARGET_BUCKET"
aws s3api create-bucket \
  --bucket $TARGET_BUCKET \
  --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION \
  --region $AWS_DEFAULT_REGION

echo "Creating the pod-identity-webhook now. Hopefully all dependencies are up and running..."
kubectl create -f pod-identity-webhook/deployment.yaml
echo "Waiting for pod-identity-webhook to be ready..."

kubectl wait --for=condition=available --timeout=300s \
  deployment/pod-identity-webhook \
  -n default

echo "pod-identity-webhook is ready! Creating the echoer..."

kubectl create sa s3-echoer
kubectl annotate sa s3-echoer eks.amazonaws.com/role-arn=$S3_ROLE_ARN
sed -e "s;SUFFIX;${suffix};g" -e "s;AWS_REGION_PLACEHOLDER;${AWS_DEFAULT_REGION};g" templates/s3-echoer/s3-echoer-job.template.yaml >"$STACK_DIR/echoer/s3-echoer.yaml"
kubectl create -f "$STACK_DIR/echoer/s3-echoer.yaml"

echo "The Demo S3 bucket as below:"
echo $TARGET_BUCKET
