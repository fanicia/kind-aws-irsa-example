# README

## Introduction

This repository shows off how you can use IAM Roles for Service Accounts (IRSA) in self-hosted Kubernetes clusters.
As this is a demo-type repository, I just spin up a Kind cluster here, but the technique should work for production-level clusters just as well.
Furthermore, to avoid gold-plating this project out of the gate, I have included a few hacks to get things working.

## How to run it?

Simply run the `full-setup.sh` script, and you should get a kind cluster with a Job `s3-echoer` that authenticates to your AWS Account and places a file in an output-bucket as a demo.
The script automatically waits for all dependencies (cert-manager, pod-identity-webhook) to be ready before proceeding.

Each run automatically generates a unique UUID-based identifier, allowing multiple isolated stacks to run simultaneously. If you want to use a specific identifier (for reproducibility or named stacks), provide it as an argument:

```bash
./full-setup.sh "my-dev-stack"
```


## Prerequisites

To run the script you need to have credentials for an AWS Account and have the following binaries installed:

* `kubectl`
* `aws-cli`
* `jq`
* `go`
* `kind`
* `uuidgen`
* `ssh-keygen`
* `openssl`
* `fzf` (optional, for interactive stack selection during teardown)


## Cleaning up

To clean up all resources created by the setup script, run:

```bash
./full-taredown.sh
```

The teardown script will automatically detect deployed stacks and present an interactive menu (if `fzf` is installed and multiple stacks exist). You can also specify a suffix directly:

```bash
./full-taredown.sh <suffix>
```

This script will delete:
- Kind cluster (`irsa-<suffix>`)
- IAM role (`s3-echoer-<suffix>`)
- OIDC provider (`s3.us-east-2.amazonaws.com/aws-irsa-oidc-discovery-<suffix>`)
- S3 buckets (`aws-irsa-oidc-discovery-<suffix>` and `output-bucket-s3-echoer-<suffix>`)
- Local files specific to the stack (keys, configs, and generated manifests)
- Empty `aws/` and `echoer/` directories (if no other stacks remain)

## Costs

I have run the script a bunch of times and I am yet to see *any* impact on the cost of my personal AWS Account, so if you clean up after using the script, you should not worry about the cost of the script.
That said, I do not take responsibility of any costs you may see as a result of trying out the script.
Always be careful not to over-provision anything in AWS as it can be an expensive playground to use if not done right.

## Inspiration

This repository draws very heavily upon the AWS-created repository [amazon-eks-pod-identity-webhook](https://github.com/aws/amazon-eks-pod-identity-webhook) and specifically, their guide on doing a [self-hosted setup](https://github.com/aws/amazon-eks-pod-identity-webhook/blob/master/SELF_HOSTED_SETUP.md).
My contribution to the topic is primarily putting the pieces together in a script that runs everything in one go.

