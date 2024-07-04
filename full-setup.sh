## Pre-reqs. Have creds for an AWS account, have kubectl, aws-cli, jq, go and kind installed.

# don't paginate the results from the AWS cli
export AWS_PAGER=""

# bootstrap stuff
suffix="run-1"

SHORT_SLEEP_TIME="60"
SLEEP_TIME="120"

# Generate keys for k8s configuration
rm -rf keys
mkdir -p keys

# create S3 Bucket
export AWS_DEFAULT_REGION="eu-west-1"
export S3_BUCKET="aws-irsa-oidc-$suffix"

# Generate the keypair
PRIV_KEY="keys/oidc-issuer.key"
PUB_KEY="keys/oidc-issuer.key.pub"
PKCS_KEY="keys/oidc-issuer.pub"

# Generate a key pair
ssh-keygen -t rsa -b 2048 -f $PRIV_KEY -m pem -N ""

# convert the SSH pubkey to PKCS8
ssh-keygen -e -m PKCS8 -f $PUB_KEY >$PKCS_KEY

aws s3api create-bucket --bucket $S3_BUCKET --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION

export HOSTNAME=s3-$AWS_DEFAULT_REGION.amazonaws.com
export ISSUER_HOSTPATH=$HOSTNAME/$S3_BUCKET

aws s3api put-public-access-block --bucket $S3_BUCKET --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

cat <<EOF >s3-readonly-policy.json
{
    "Version": "2008-10-17",
    "Statement": [
        {
            "Sid": "AllowPublicRead",
            "Effect": "Allow",
            "Principal": {
                "AWS": "*"
            },
            "Action": [
                "s3:GetObject"
            ],
            "Resource": [
                "arn:aws:s3:::$S3_BUCKET/*"
            ]
        }
    ]
}
EOF
aws s3api put-bucket-policy --bucket $S3_BUCKET --policy file://s3-readonly-policy.json

# Create discover.json and keys.json
cat <<EOF >discovery.json
{
    "issuer": "https://$ISSUER_HOSTPATH/",
    "jwks_uri": "https://$ISSUER_HOSTPATH/keys.json",
    "authorization_endpoint": "urn:kubernetes:programmatic_authorization",
    "response_types_supported": [
        "id_token"
    ],
    "subject_types_supported": [
        "public"
    ],
    "id_token_signing_alg_values_supported": [
        "RS256"
    ],
    "claims_supported": [
        "sub",
        "iss"
    ]
}
EOF
#
# This assumes  k8s cluster > 1.16. if not, see https://github.com/aws/amazon-eks-pod-identity-webhook/blob/master/SELF_HOSTED_SETUP.md
go run ./main.go -key $PKCS_KEY | jq >keys.json

aws s3 cp ./discovery.json s3://$S3_BUCKET/.well-known/openid-configuration
aws s3 cp ./keys.json s3://$S3_BUCKET/keys.json

# Create OIDC identity provider
export CA_THUMBPRINT=$(openssl s_client -connect s3-$AWS_DEFAULT_REGION.amazonaws.com:443 -servername s3-$AWS_DEFAULT_REGION.amazonaws.com -showcerts </dev/null 2>/dev/null | openssl x509 -in /dev/stdin -sha1 -noout -fingerprint | cut -d '=' -f 2 | tr -d ':')

aws iam create-open-id-connect-provider \
	--url https://$ISSUER_HOSTPATH \
	--thumbprint-list $CA_THUMBPRINT \
	--client-id-list sts.amazonaws.com

echo "The service-account-issuer as below:"
echo "https://$ISSUER_HOSTPATH"

# Setup k8s cluster:
kind delete cluster --name irsa

cat <<EOF >kind-irsa-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
- |-
  kind: ClusterConfiguration
  apiServer:
    extraArgs:
      service-account-signing-key-file: /etc/ca-certificates/irsa/oidc-issuer.key
      service-account-key-file: /etc/ca-certificates/irsa/oidc-issuer.pub
      api-audiences: sts.amazonaws.com
      service-account-issuer: https://s3-eu-west-1.amazonaws.com/$S3_BUCKET
nodes:
- role: control-plane
  extraMounts:
  - hostPath: $PWD/keys/ # <-- only use full paths here. local paths won't work
    containerPath: /etc/ca-certificates/irsa/ # <-- Make sure to use a path under /ca-certificates as that is mounted in to the apiserver
    readOnly: true
- role: worker
EOF

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

##### Deploy echoer

export ISSUER_URL="https://s3-eu-west-1.amazonaws.com/$S3_BUCKET"

# create iam role for s3 echoer job
export ISSUER_HOSTPATH=$(echo $ISSUER_URL | cut -f 3- -d'/')
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$ISSUER_HOSTPATH"
export ROLE_NAME="s3-echoer-$suffix"

cat >irp-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "$PROVIDER_ARN"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${ISSUER_HOSTPATH}:sub": "system:serviceaccount:default:s3-echoer"
        }
      }
    }
  ]
}
EOF

echo "Creating Demo role: $ROLE_NAME"
aws iam create-role \
	--role-name $ROLE_NAME \
	--assume-role-policy-document file://irp-trust-policy.json

aws iam attach-role-policy \
	--role-name $ROLE_NAME \
	--policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# create service account for s3 echoer job and attach the iam role
export S3_ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text)

# deploy s3 echoer job into k8s cluster
export TARGET_BUCKET="demo-bucket-$ROLE_NAME"

kubectl create sa s3-echoer
kubectl annotate sa s3-echoer eks.amazonaws.com/role-arn=$S3_ROLE_ARN

echo "Creating demo target-bucket: $TARGET_BUCKET"
aws s3api create-bucket \
	--bucket $TARGET_BUCKET \
	--create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION \
	--region $AWS_DEFAULT_REGION

echo "Creating the pod-identity-webhook now. Hopefully all dependencies are up and running..."
kubectl create -f pod-identity-webhook/deployment.yaml
echo "Almost there. Let's just give the webhook some time to get started ⏲"
sleep $SHORT_SLEEP_TIME
echo "Creating the echoer. Cross your fingers!"

sed -e "s/TIMESTAMP/${suffix}/g" s3-echoer-job/s3-echoer-job.yaml.template >s3-echoer.yaml
kubectl create -f s3-echoer.yaml

echo "The Demo S3 bucket as below:"
echo $TARGET_BUCKET
