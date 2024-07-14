# README

## Introduction

This repository shows off how you can use IAM Roles for Service Accounts (IRSA) in self-hosted Kubernetes clusters.
As this is a demo-type repository, I just spin up a Kind cluster here, but the technique should work for production-level clusters just as well.
Furthermore, to avoid gold-plating this project out of the gate, I have included a few hacks to get things working.

## How to run it?

Simply run the `full-setup.sh` script, and you should get a kind cluster with a Job `s3-echoer` that authenticates to your AWS Account and places a file in an output-bucket as a demo.
As this script spins up a few different resources that depend on each other, you may need to adjust the `SLEEP_TIME` variable in the top of the script to allow longer time for resources to come up
if you are running on older hardware.

If you want to do multiple runs of the script in a row, you can tweak the `suffix` variable and set it to e.g. `run-1`, `run-2`, etc.
That way, the buckets and other resources created will not clash on the naming between runs.


## Prerequisites

To run the script you need to have credentials for an AWS Account and have the following binaries installed:

* `kubectl`
* `aws-cli`
* `jq`
* `go`
* `kind`


## Cleaning up

Once you have run the script, you should remember to clean up in your AWS Account.
The script will create two buckets: `aws-irsa-oidc-discovery-run-X` and `output-bucket-s3-echoer-run-X`, an identity-provider `s3-eu-west-1.amazonaws.com/aws-irsa-oidc-discovery-run-X` and a role `s3-echoer-run-X`, which can be cleaned up using the aws-cli or the AWS Console.

Long-term I may include a smarter way of cleaning up after a run, but I have skipped that for now.

## Costs

I have run the script a bunch of times and I am yet to see *any* impact on the cost of my personal AWS Account, so if you clean up after using the script, you should not worry about the cost of the script.
That said, I do not take responsibility of any costs you may see as a result of trying out the script.
Always be careful not to over-provision anything in AWS as it can be an expensive playground to use if not done right.

## Inspiration

This repository draws very heavily upon the AWS-created repository [amazon-eks-pod-identity-webhook](https://github.com/aws/amazon-eks-pod-identity-webhook) and specifically, their guide on doing a [self-hosted setup](https://github.com/aws/amazon-eks-pod-identity-webhook/blob/master/SELF_HOSTED_SETUP.md).
My contribution to the topic is primarily putting the pieces together in a script that runs everything in one go.

