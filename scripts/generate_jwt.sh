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

HEADER='{"alg":"RS256","typ":"JWT"}'

# JWT Payload: issued at (iat) and expiration (exp) timestamps
NOW=$(date +%s)
EXP=$(($NOW + 600))  # 10 minutes validity
PAYLOAD="{\"iat\":$NOW,\"exp\":$EXP,\"iss\":$APP_ID}"

# Encode header and payload
HEADER_B64=$(echo -n "$HEADER" | openssl base64 -A | tr -d '=' | tr '/+' '_-')
PAYLOAD_B64=$(echo -n "$PAYLOAD" | openssl base64 -A | tr -d '=' | tr '/+' '_-')

# Generate signature
SIGNATURE=$(echo -n "$HEADER_B64.$PAYLOAD_B64" | \
    openssl dgst -sha256 -sign "$PRIVATE_KEY" | \
    openssl base64 -A | tr -d '=' | tr '/+' '_-')

# Final JWT token
JWT="$HEADER_B64.$PAYLOAD_B64.$SIGNATURE"

echo "JWT: $JWT"