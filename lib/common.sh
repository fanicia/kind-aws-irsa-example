#!/bin/bash

export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-1}"

# Check if required binaries are installed. Exits with error if any are missing.
# Usage: check_prerequisites cmd1 cmd2 cmd3 ...
check_prerequisites() {
    local missing=()

    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: Missing required binaries:" >&2
        for cmd in "${missing[@]}"; do
            echo "  - $cmd" >&2
        done
        echo "" >&2
        echo "Please install the missing prerequisites and try again." >&2
        exit 1
    fi
}

# Generate a numeric suffix from an input string using md5 hash.
# This creates consistent, collision-resistant identifiers for AWS resources.
# Usage: suffix=$(generate_suffix "input-string")
generate_suffix() {
    local input_string="$1"
    local hash_hex=$(echo -n "$input_string" | md5sum | cut -f 1 -d " " | cut -c 1-4)
    echo "$((0x$hash_hex))"
}

# List all deployed stacks by querying AWS S3 for OIDC discovery buckets.
# Returns one suffix per line. Returns 1 if no stacks found.
# Usage: stacks=$(list_deployed_stacks)
list_deployed_stacks() {
    local buckets=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'aws-irsa-oidc-discovery-')].Name" --output text 2>/dev/null)

    if [ -z "$buckets" ]; then
        return 1
    fi

    for bucket in $buckets; do
        local suffix="${bucket#aws-irsa-oidc-discovery-}"
        echo "$suffix"
    done
}

# Interactive stack selection using fzf.
# Returns selected suffix or exits with error if no selection made.
# If only one stack exists, returns it automatically.
# Usage: suffix=$(select_stack_interactive)
select_stack_interactive() {
    local stacks=$(list_deployed_stacks)

    if [ -z "$stacks" ]; then
        echo "No deployed stacks found" >&2
        return 1
    fi

    local stack_count=$(echo "$stacks" | wc -l)

    if [ "$stack_count" -eq 1 ]; then
        echo "$stacks"
        return 0
    fi

    if ! command -v fzf &> /dev/null; then
        echo "Multiple stacks found but fzf is not installed. Please specify suffix manually." >&2
        return 1
    fi

    local selected=$(echo "$stacks" | fzf --prompt="Select stack to teardown: " --height=40%)

    if [ -z "$selected" ]; then
        echo "No stack selected" >&2
        return 1
    fi

    echo "$selected"
}

# Generate AWS resource names based on suffix.
# Exports environment variables for bucket names, role name, etc.
# Usage: get_resource_names "12345"
get_resource_names() {
    local suffix="$1"
    export DISCOVERY_BUCKET="aws-irsa-oidc-discovery-$suffix"
    export HOSTNAME="s3-$AWS_DEFAULT_REGION.amazonaws.com"
    export ISSUER_HOSTPATH="$HOSTNAME/$DISCOVERY_BUCKET"
    export ROLE_NAME="s3-echoer-$suffix"
    export TARGET_BUCKET="output-bucket-$ROLE_NAME"
}