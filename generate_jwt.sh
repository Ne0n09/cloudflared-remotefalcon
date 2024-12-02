#!/bin/bash
# Generate a JWT using bash for use with the RF external-api


# Name of the container to check
container_name="mongo"

# Check if the container exists
if sudo docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "Container '${container_name}' is running."
    echo "Finding API details..."
    echo
    # Display API details from mongo:
    sudo docker exec -it mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
        db = db.getSiblingDB(\"remote-falcon\");
        db.show.aggregate([
            { \$match: { \"apiAccess.apiAccessActive\": true } },
            { \$project: { _id: 0, showName: \"\$showName\", apiAccessToken: \"\$apiAccess.apiAccessToken\", apiAccessSecret: \"\$apiAccess.apiAccessSecret\" } }
        ]);
    '"
    echo "Done"
    echo
fi

# Ask for accessToken and secretKey
read -p "Enter your apiAccessToken: " accessToken
accessToken=$accessToken
echo $accessToken
echo

read -p "Enter your apiAccessSecret: " secretKey
secretKey=$secretKey
echo $secretKey
echo

# Create Header (JSON)
header='{"typ":"JWT","alg":"HS256"}'
# Create Payload (JSON)
payload="{\"accessToken\":\"$accessToken\"}"

# Base64Url encode a string (use OpenSSL and replace URL unsafe characters)
base64url_encode() {
    echo -n "$1" | openssl base64 -e | tr -d '\n=' | tr '+/' '-_' 
}

# Encode Header and Payload to Base64Url
base64UrlHeader=$(base64url_encode "$header")
base64UrlPayload=$(base64url_encode "$payload")

# Create Signature (HMAC with SHA256)
signature=$(echo -n "$base64UrlHeader.$base64UrlPayload" | openssl dgst -sha256 -hmac "$secretKey" -binary | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

# Create JWT
jwt="$base64UrlHeader.$base64UrlPayload.$signature"

# Output JWT
echo "Your JWT is: "
echo $jwt