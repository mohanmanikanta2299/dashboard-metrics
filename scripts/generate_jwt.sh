#!/bin/bash
set -e

GH_APP_ID=$1
PRIVATE_KEY=$2

# Ensure required parameters are provided
if [[ -z "$GH_APP_ID" || -z "$PRIVATE_KEY" ]]; then
    echo "Error: Missing required parameters."
    echo "Usage: $0 <GH_APP_ID> <GH_APP_PRIVATE_KEY>"
    exit 1
fi

# Write private key to a temporary file
PRIVATE_KEY_FILE=$(mktemp)
echo -e "$PRIVATE_KEY" | sed 's/\\n/\n/g' > "$PRIVATE_KEY_FILE"
chmod 600 "$PRIVATE_KEY_FILE"  # Secure the key file

HEADER='{"alg":"RS256","typ":"JWT"}'

# JWT Payload: issued at (iat) and expiration (exp) timestamps
NOW=$(date +%s)
EXP=$(($NOW + 600))  # 10 minutes validity
PAYLOAD="{\"iat\":$NOW,\"exp\":$EXP,\"iss\":$GH_APP_ID}"

# Encode header and payload
HEADER_B64=$(echo -n "$HEADER" | openssl base64 -A | tr -d '=' | tr '/+' '_-')
PAYLOAD_B64=$(echo -n "$PAYLOAD" | openssl base64 -A | tr -d '=' | tr '/+' '_-')

# Generate signature using the temporary private key file
SIGNATURE=$(echo -n "$HEADER_B64.$PAYLOAD_B64" | \
    openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | \
    openssl base64 -A | tr -d '=' | tr '/+' '_-')

# Clean up private key file
rm -f "$PRIVATE_KEY_FILE"

# Final JWT token
JWT="$HEADER_B64.$PAYLOAD_B64.$SIGNATURE"

# Output JWT
echo "$JWT"