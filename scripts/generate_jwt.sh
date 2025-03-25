#!/bin/bash
set -e

GH_APP_ID=$1
PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA1GaFQEfa6fmnAwBs0r5X1vFdGSV2x7mq6KW8fbUpyp8skt0D
YZD41YYkh7nwUSc2hy1zd3rC4/PlAU4m7jH/SYnVOS66+kLp8MMpkCuk+TNdndGA
YQBVVyzFb80Je0CeOzhyPO2O4y6Hs4vXoLQkggK2BZx4FMJYoAWEuV5a4Ag6jtVb
f8ENrX4txVLQFsaOJPj868hsKH4xCqwHwxHJDq5KRV1ZQLPUx6wmkIj2rbc+V/e9
kPY6kGOvxxekpo+lQ8BT/pV1+ujDX5vEKjYRdeU5vSOPKHbK0+4P/aJn/cQXMkfA
CU9xFxl6S9mZj2P8D05yVzsu1iV/4pIQ/LR3qwIDAQABAoIBAQCUTSzW8BTi70R0
bRSOpQZx9r7ZMvZXh8TUgfw1DYwrhK47sQOOWQnVFL9m4SXxk96Xzd1kXBu9y+pm
2emGwPQNpaZyMbWtzZDIYYwgtMiQkxPXgJMRp4juwDzuzgvDuh+BG+1vqzLsXu2z
KH4bIAypljj/e/vACt6UhKXiRAZRi0bmE8Yy1Zm7ygO9jf9dY8BqRQCmF3zeAg60
HjelFjRttGj287IrMc605A9oY3kXuppoo75oK7/3mQ3ohjbbXInRS6w6Gr7D4Xdh
7+9+jeC80tSGfo5rRqjKNnt6HOHkt3hR95kocoEKALSKeJqrlujeCg0oIk3BSktJ
itna4ClRAoGBAPnsDmmn6Z6KPTVQfzfBRIet2N+xZqGiTJ6ttYTkjW+qZz1H/vkR
kVF5qFq9SZgWZ8kpH61eNYrTdANib6jXOijf/Nr5YucJcxJItQJsFZhhpQFkLUz8
+h0xdKmwTaSIK1xaVG1ZU+cGUnE3j8wVI7XLyuk6OocpoA1nmF0UfpPZAoGBANmQ
3YLwfI8dJV6o22wYjgyKdqDfUx9bWeYRRmcDKXgC1TzN2zHOXF3RR9GBuBow9GDI
ssDLrDFlFdHViUo4NltgmCVSYqZQSpFSS/WbV/U2UBFElhJ+hrKb4eEQqAyZT15d
Ep465vW9lpnAtIozx3azkSsaEBdFLctjt9parKkjAoGAfm1kyRwROYtS9WJ4SLsz
MLPILzjt4zxYKDlVxxlbVy7LtRtzp4m0ipPRj72Lui0zaXatOKWczlKzsHaeZ7oh
CMZuglOALcIA/THcp5IHxqM2tqJ3rCeZWyVGkATI8j+UN87WQM7ce9Ud5Xom+yWC
gBfM2PkE3JU5Cy7py8RvV9kCgYBCqDalumZ/Nm/Pm652ZOOIhheoXCPMdKGLcnl+
cCKRaVTJp0xj6xSzjb4SO0sbgyosSPEzTnN4Qr83pdPFUIme325d6Oreh7UA5xTs
r+Z382b+k2PjUK6WJFpFKWRDT+lYQO3GWseOPMLaYoct3IVdIdD1QqvxZTmNmgSn
OqaxvwKBgBMAE6A6pVUQKslCoGWKs9MUaCDN4BlcUR2CjgHYiieXj0EYKnOfe4dl
M1sMOxUx4zFhNieRlfjMkKaiiUqLGp94yXaVWN2Hjqyn0ay26Pgl/lvrhKfsmSno
xaC3dqMjyfc4g4b4DHwhlMabVNB7Ry0YS2f1o5CtNvaG+/m5e9pi
-----END RSA PRIVATE KEY-----"

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