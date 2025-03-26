#!/bin/bash
set -e

GH_APP_ID=$1
GH_APP_INSTALLATION_ID=$2

# Ensure required parameters are provided
if [[ -z "$GH_APP_ID" || -z "$GH_APP_INSTALLATION_ID" ]]; then
    echo "Error: Missing required parameters."
    echo "Usage: $0 <GH_APP_ID> <GH_APP_INSTALLATION_ID>"
    exit 1
fi

EXPIRATION=$(( $(date +%s) + 600 )) # 10 minutes expiration

# JWT Header
HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr -d '=' | tr '/+' '_-')

# JWT Payload
PAYLOAD=$(echo -n "{\"iat\":$(date +%s),\"exp\":$EXPIRATION,\"iss\":$GH_APP_ID}" | openssl base64 -A | tr -d '=' | tr '/+' '_-')

# Generate signature
SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" | openssl dgst -sha256 -sign private-key.pem | openssl base64 -A | tr -d '=' | tr '/+' '_-')

# JWT Token
JWT="$HEADER.$PAYLOAD.$SIGNATURE"

# Debug: Print JWT Length (do NOT print actual JWT for security reasons)
echo "JWT Length: ${#JWT}"

# Check if JWT is empty
if [ -z "$JWT" ]; then
    echo "Error: JWT is empty!"
    exit 1
fi

echo "Generated JWT: $JWT"

INSTALLATION_TOKEN=$(curl -s -X POST \
            -H "Authorization: Bearer $JWT" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/app/installations/$GH_APP_INSTALLATION_ID/access_tokens" | jq -r .token)

if [ -z "$INSTALLATION_TOKEN" ] || [ "$INSTALLATION_TOKEN" == "null" ]; then
    echo "Failed to get installation token"
    exit 1
fi

echo "$INSTALLATION_TOKEN"