# Pre-reqs: Have creds for an AWS account, have kubectl, aws-cli, jq, go and kind installed.

# Unset pager for Linux users
export AWS_PAGER=""

# By changing the suffix, you can have multiple "versions" running at a time.
# This is just a hacky way of easily running the script multiple times after each other with a fresh state.
# Long-term, I should probably just have a clean-up script to call in between the runs.
suffix="run-1"

# Note: For slower hardware, you may need to bump this higher
# Otherwise, you may see cert-manager not starting up in time to sign the certificate needed for the webhook
# I recommend watching along with k9s or manual kubectl commands to check that things start up in the right order.
SLEEP_TIME="20"

# Generate keys for k8s configuration
rm -rf keys
mkdir -p keys

# make folder if it doesn't exist
mkdir -p aws
mkdir -p echoer

# create S3 Bucket
export AWS_DEFAULT_REGION="eu-west-1"
export DISCOVERY_BUCKET="aws-irsa-oidc-discovery-$suffix"

aws s3api create-bucket --bucket $DISCOVERY_BUCKET --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION

export HOSTNAME=s3-$AWS_DEFAULT_REGION.amazonaws.com
export ISSUER_HOSTPATH=$HOSTNAME/$DISCOVERY_BUCKET

aws s3api put-public-access-block --bucket $DISCOVERY_BUCKET --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# poor man's templating using sed. note the use of \ as a delimiter to avoid clashing with characters in the templating files.
sed -e "s\DISCOVERY_BUCKET\\${DISCOVERY_BUCKET}\g" templates/aws/s3-readonly-policy.template.json >aws/s3-readonly-policy.json
aws s3api put-bucket-policy --bucket $DISCOVERY_BUCKET --policy file://aws/s3-readonly-policy.json

# Generate the keypair
PRIV_KEY="keys/oidc-issuer.key"
PUB_KEY="keys/oidc-issuer.key.pub"
PKCS_KEY="keys/oidc-issuer.pub"

# Generate a key pair
ssh-keygen -t rsa -b 2048 -f $PRIV_KEY -m pem -N ""

# convert the SSH pubkey to PKCS8
ssh-keygen -e -m PKCS8 -f $PUB_KEY >$PKCS_KEY

# Use the PKCS_KEY to generate the JWKS key set for the JWKS endpoint of the Discovery Bucket
go run -C keys-generator main.go -key "$PWD/$PKCS_KEY" | jq >aws/keys.json

# Create and place discovery.json and keys.json in the discovery-bucket
sed -e "s\ISSUER_HOSTPATH\\${ISSUER_HOSTPATH}\g" templates/aws/discovery.template.json >aws/discovery.json
aws s3 cp ./aws/discovery.json s3://$DISCOVERY_BUCKET/.well-known/openid-configuration
aws s3 cp ./aws/keys.json s3://$DISCOVERY_BUCKET/keys.json

echo "The service-account-issuer as below:"
echo "https://$ISSUER_HOSTPATH"

# Create OIDC identity provider
export CA_THUMBPRINT=$(openssl s_client -connect s3-$AWS_DEFAULT_REGION.amazonaws.com:443 -servername s3-$AWS_DEFAULT_REGION.amazonaws.com -showcerts </dev/null 2>/dev/null | openssl x509 -in /dev/stdin -sha1 -noout -fingerprint | cut -d '=' -f 2 | tr -d ':')

aws iam create-open-id-connect-provider \
  --url https://$ISSUER_HOSTPATH \
  --thumbprint-list $CA_THUMBPRINT \
  --client-id-list sts.amazonaws.com

# Setup k8s cluster:
kind delete cluster --name irsa

sed -e "s\PWD\\${PWD}\g; s\DISCOVERY_BUCKET\\${DISCOVERY_BUCKET}\g" templates/kind/irsa-config.template.yaml >kind-irsa-config.yaml
kind create cluster --config kind-irsa-config.yaml --name irsa
echo "Cluster has been set up. Setting up cert manager in a couple of seconds:"

# Install cert manager instead of messing with certs manually:
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.6/cert-manager.yaml
echo "cert manager has been applied. waiting a little bit again"

sleep $SLEEP_TIME

# Setup k8s webhook auth stuff up. Heavily inspired by https://github.com/aws/amazon-eks-pod-identity-webhook/tree/master/deploy
kubectl create -f pod-identity-webhook/auth.yaml
kubectl create -f pod-identity-webhook/service.yaml
kubectl create -f pod-identity-webhook/cert.yaml
kubectl create -f pod-identity-webhook/mutatingwebhook-ca-bundle.yaml

# create iam role for s3 echoer job
export ISSUER_URL="https://s3-eu-west-1.amazonaws.com/$DISCOVERY_BUCKET"
export ISSUER_HOSTPATH=$(echo $ISSUER_URL | cut -f 3- -d'/')
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$ISSUER_HOSTPATH"
export ROLE_NAME="s3-echoer-$suffix"

echo "Creating Demo role: $ROLE_NAME"
sed -e "s\PROVIDER_ARN\\${PROVIDER_ARN}\g; s\ISSUER_HOSTPATH\\${ISSUER_HOSTPATH}\g" templates/aws/irp-trust-policy.template.json >aws/irp-trust-policy.json
aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document file://aws/irp-trust-policy.json

aws iam attach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# create service account for s3 echoer job and attach the iam role
export S3_ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text)

# deploy s3 echoer job into k8s cluster
export TARGET_BUCKET="output-bucket-$ROLE_NAME"

kubectl create sa s3-echoer
kubectl annotate sa s3-echoer eks.amazonaws.com/role-arn=$S3_ROLE_ARN

echo "Creating demo target-bucket: $TARGET_BUCKET"
aws s3api create-bucket \
  --bucket $TARGET_BUCKET \
  --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION \
  --region $AWS_DEFAULT_REGION

echo "Creating the pod-identity-webhook now. Hopefully all dependencies are up and running..."
kubectl create -f pod-identity-webhook/deployment.yaml
echo "Almost there. Let's just give the webhook some time to get started. It needs to be ready before the echoer is deployed"
sleep $SLEEP_TIME
echo "Creating the echoer. Cross your fingers!"

sed -e "s/SUFFIX/${suffix}/g" templates/s3-echoer/s3-echoer-job.template.yaml >echoer/s3-echoer.yaml
kubectl create -f echoer/s3-echoer.yaml

echo "The Demo S3 bucket as below:"
echo $TARGET_BUCKET
