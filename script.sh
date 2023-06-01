#!/bin/bash
#MZC TODO: This isn't finished and it will behave slightly different on different platforms

# Parse command-line arguments
while getopts "k:" opt; do
  case $opt in
    k)
      keyFile="$OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

if [[ -z "$keyFile" ]]; then
  echo "Missing required argument: -k <key file>"
  exit 1
fi

# Read the key file
content=$(cat "$keyFile")

# Extract the public key in PEM format
publicKey=$(openssl rsa -in <(echo "$content") -pubin -outform PEM)

# Get the public key ID
pkSha=$(echo "$publicKey" | openssl rsa -pubin -outform DER | openssl dgst -sha256 -binary)
# keyID=$(echo $pkPreBase64 | base64 -w0 | tr '+/' '-_') with -w0
keyID=$(echo $pkSha | openssl base64 -A)

# Prepare the JSON response
response='{
  "keys": [
    {
      "kty": "RSA",
      "alg": "RS256",
      "use": "sig",
      "kid": "'"${keyID}"'",
      "n": ??
      "e": ??
    }
  ]
}'

# Pretty print the JSON response
formattedResponse=$(echo "$response" | jq '.')

echo "$formattedResponse"
