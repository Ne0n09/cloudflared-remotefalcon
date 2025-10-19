#!/bin/bash

# VERSION=2025.10.19.1

# This script assist with automatically setting up Cloudflare domain, certificate, SSL/TLS, tunnel, and DNS settings.
# A Cloudflare API Token with appropriate permissions is required.
# Required API Token Permissions:
## Account Permissions:
### Account → Account Settings → Read (to retrieve Account ID)
### Account → Cloudflare Tunnel → Edit (to create and configure tunnels)

## Zone Permissions:
### Zone → Zone → Edit (to add domains to Cloudflare)
### Zone → DNS → Edit (to create DNS records)
### Zone → SSL and Certificates → Edit (to configure SSL settings and create origin certificates)

# Account Resources:
## All accounts (or select a specific account if you prefer)

# Zone Resources:
## All zones (recommended) OR All zones from an account

set -e

# ========== Color Codes ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Paths
ENV_FILE="./remotefalcon/.env"
CERT_DIR="./remotefalcon"

echo -e "${BLUE}⚙️ Running setup Cloudflare script...${NC}"

check_requirements() {
  echo -e "${BLUE}⚙️ Checking requirements...${NC}"
  local missing_tools=()
  command -v curl >/dev/null 2>&1 || missing_tools+=("curl")
  command -v jq >/dev/null 2>&1 || missing_tools+=("jq")
  command -v openssl >/dev/null 2>&1 || missing_tools+=("openssl")
  
  if [ ${#missing_tools[@]} -ne 0 ]; then
    echo -e "${RED}❌ Missing required tools: ${missing_tools[*]}${NC}"
    echo -e "${YELLOW}⚠️ Install them with: sudo apt-get install ${missing_tools[*]}${NC}"
    exit 1
  fi
  echo -e "${GREEN}✔ All requirements met${NC}"
}

validate_domain() {
  local domain=$1
  [[ $domain =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

read_env_file() {
  echo -e "${BLUE}🔍 Reading configuration from ${ENV_FILE}...${NC}"
  
  if [ ! -f "${ENV_FILE}" ]; then
    echo -e "${RED}❌ .env file not found at ${ENV_FILE}${NC}"
    exit 1
  fi
  
  mkdir -p "${CERT_DIR}"
  DOMAIN=$(grep -E "^DOMAIN=" "${ENV_FILE}" | cut -d '=' -f2- | tr -d '"' | tr -d "'" | xargs)
  
  if [ -z "${DOMAIN}" ] || [ "${DOMAIN}" = "your_domain.com" ]; then
    echo -e "${YELLOW}⚠️ DOMAIN is not set or is placeholder value${NC}"
    while true; do
      read -rp "🌐 Enter your domain name (e.g., example.com): " DOMAIN
      if validate_domain "${DOMAIN}"; then
        echo -e "${GREEN}✔ Domain format is valid: ${DOMAIN}${NC}"
        break
      else
        echo -e "${RED}❌ Invalid domain format${NC}"
      fi
    done
    
    if grep -q "^DOMAIN=" "${ENV_FILE}"; then
      sed -i.bak "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" "${ENV_FILE}"
    else
      echo "DOMAIN=${DOMAIN}" >> "${ENV_FILE}"
    fi
    echo -e "${GREEN}✔ Updated DOMAIN in ${ENV_FILE}${NC}"
  else
    echo -e "${GREEN}✔ Found DOMAIN: ${DOMAIN}${NC}"
    if ! validate_domain "${DOMAIN}"; then
      echo -e "${RED}❌ Invalid DOMAIN format${NC}"
      exit 1
    fi
  fi
}

update_tunnel_token() {
  local token=$1
  echo -e "${BLUE}🔄 Updating TUNNEL_TOKEN in ${ENV_FILE}...${NC}"
  
  if grep -q "^TUNNEL_TOKEN=" "${ENV_FILE}"; then
    sed -i.bak "s|^TUNNEL_TOKEN=.*|TUNNEL_TOKEN=${token}|" "${ENV_FILE}"
  else
    echo "TUNNEL_TOKEN=${token}" >> "${ENV_FILE}"
  fi
  echo -e "${GREEN}✔ Updated TUNNEL_TOKEN${NC}"
}

get_account_id() {
  echo -e "${BLUE}🔍 Retrieving Cloudflare Account ID...${NC}"
  
  ACCOUNTS_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" \
       -H "Content-Type: application/json")
  
  if echo "$ACCOUNTS_RESPONSE" | jq -e '.success' > /dev/null; then
    ACCOUNT_COUNT=$(echo "$ACCOUNTS_RESPONSE" | jq -r '.result | length')
    
    if [ "$ACCOUNT_COUNT" -eq 0 ]; then
      echo -e "${RED}❌ No accounts found${NC}"
      exit 1
    elif [ "$ACCOUNT_COUNT" -eq 1 ]; then
      CF_ACCOUNT_ID=$(echo "$ACCOUNTS_RESPONSE" | jq -r '.result[0].id')
      ACCOUNT_NAME=$(echo "$ACCOUNTS_RESPONSE" | jq -r '.result[0].name')
      echo -e "${GREEN}✔ Found account: ${ACCOUNT_NAME}${NC}"
    else
      echo -e "${YELLOW}⚠️ Multiple accounts found:${NC}"
      echo "$ACCOUNTS_RESPONSE" | jq -r '.result[] | "\(.id) - \(.name)"' | nl
      read -rp "❓ Enter account number: " ACCOUNT_SELECTION
      CF_ACCOUNT_ID=$(echo "$ACCOUNTS_RESPONSE" | jq -r ".result[$((ACCOUNT_SELECTION-1))].id")
      echo -e "${GREEN}✔ Selected account${NC}"
    fi
  else
    echo -e "${RED}❌ Failed to retrieve account information${NC}"
    exit 1
  fi
}

get_user_input() {
  echo -e "${BLUE}⚙️ Starting Cloudflare setup for ${RED}Remote Falcon${NC}...${NC}"
  echo
  read -rp "🔑 Enter your Cloudflare API Token: " CF_API_TOKEN
  TUNNEL_NAME="rf-${DOMAIN}"
  echo
}

add_domain_to_cloudflare() {
  echo -e "${BLUE}🔍 Checking if domain exists in Cloudflare...${NC}"
  
  ZONES_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" \
       -H "Content-Type: application/json")
  
  ZONE_COUNT=$(echo "$ZONES_RESPONSE" | jq -r '.result | length')
  
  if [ "$ZONE_COUNT" -gt 0 ]; then
    CF_ZONE_ID=$(echo "$ZONES_RESPONSE" | jq -r '.result[0].id')
    ZONE_STATUS=$(echo "$ZONES_RESPONSE" | jq -r '.result[0].status')
    echo -e "${GREEN}✔ Domain exists in Cloudflare${NC}"
    echo -e "${CYAN}  Status: ${ZONE_STATUS}${NC}"
  else
    echo -e "${YELLOW}⚠️ Adding domain to Cloudflare...${NC}"
    
    ADD_ZONE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones" \
         -H "Authorization: Bearer ${CF_API_TOKEN}" \
         -H "Content-Type: application/json" \
         --data '{
           "name": "'"${DOMAIN}"'",
           "account": {"id": "'"${CF_ACCOUNT_ID}"'"},
           "jump_start": false
         }')
    
    if echo "$ADD_ZONE_RESPONSE" | jq -e '.success' > /dev/null; then
      CF_ZONE_ID=$(echo "$ADD_ZONE_RESPONSE" | jq -r '.result.id')
      echo -e "${GREEN}✔ Domain added${NC}"
      
      NAMESERVERS=$(echo "$ADD_ZONE_RESPONSE" | jq -r '.result.name_servers[]')
      echo
      echo -e "${YELLOW}⚠️ Update nameservers at your registrar:${NC}"
      echo "$NAMESERVERS" | while read -r ns; do echo "  - ${ns}"; done
      echo
      read -rp "Press Enter after updating nameservers..."
    else
      echo -e "${RED}❌ Failed to add domain${NC}"
      exit 1
    fi
  fi
  
  export CF_ZONE_ID
}

delete_conflicting_records() {
  echo -e "${BLUE}🔍 Checking DNS records...${NC}"
  
  RECORDS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  
  RECORD_COUNT=$(echo "$RECORDS" | jq -r '.result | length')
  
  if [ "$RECORD_COUNT" -eq 0 ]; then
    echo -e "${CYAN}ℹ️ No existing DNS records${NC}"
    return
  fi
  
  A_CNAME_RECORDS=$(echo "$RECORDS" | jq -r '.result[] | select(.type == "A" or .type == "CNAME")')
  if [ -n "$A_CNAME_RECORDS" ]; then
    A_CNAME_COUNT=$(echo "$A_CNAME_RECORDS" | jq -s 'length')
    if [ "$A_CNAME_COUNT" -gt 0 ]; then
      echo -e "${CYAN}📋 Found ${A_CNAME_COUNT} A/CNAME records${NC}"
    fi
  fi
  
  ROOT_CONFLICTS=$(echo "$RECORDS" | jq -r '.result[] | select((.type == "A" or .type == "CNAME") and (.name == "'"${DOMAIN}"'" or .name == "@")) | "\(.id)|\(.type)|\(.name)|\(.content)"')
  WILDCARD_CONFLICTS=$(echo "$RECORDS" | jq -r '.result[] | select((.type == "A" or .type == "CNAME") and (.name == "*" or .name == "*.'"${DOMAIN}"'")) | "\(.id)|\(.type)|\(.name)|\(.content)"')
  
  CONFLICTS=""
  [ -n "$ROOT_CONFLICTS" ] && CONFLICTS="$ROOT_CONFLICTS"
  [ -n "$WILDCARD_CONFLICTS" ] && CONFLICTS="${CONFLICTS:+$CONFLICTS$'\n'}$WILDCARD_CONFLICTS"
  
  if [ -z "$CONFLICTS" ]; then
    echo -e "${GREEN}✔ No conflicting DNS records${NC}"
    return
  fi
  
  echo -e "${YELLOW}⚠️ Found conflicting records:${NC}"
  echo "$CONFLICTS" | while IFS='|' read -r id type name content; do
    [ -n "$id" ] && echo -e "  ${RED}[${type}]${NC} ${name} → ${content}"
  done
  echo
  
  read -rp "❓ Delete conflicting records? (y/n): [n] " DELETE_CONFIRM
  if [[ ! "$DELETE_CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}⚠️ Skipping deletion${NC}"
    return
  fi
  
  echo "$CONFLICTS" | while IFS='|' read -r record_id type name content; do
    if [ -n "$record_id" ]; then
      curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
           -H "Authorization: Bearer ${CF_API_TOKEN}" > /dev/null
      echo -e "${GREEN}✔ Deleted: [${type}] ${name}${NC}"
    fi
  done
}

configure_ssl() {
  echo -e "${BLUE}🔒 Configuring SSL/TLS...${NC}"
  
  curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/settings/ssl" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
       --data '{"value":"strict"}' > /dev/null 2>&1
  echo -e "${GREEN}✔ SSL: Full (Strict)${NC}"
  
  curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/settings/always_use_https" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
       --data '{"value":"on"}' > /dev/null 2>&1
  echo -e "${GREEN}✔ Always Use HTTPS${NC}"
  
  curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/settings/min_tls_version" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
       --data '{"value":"1.3"}' > /dev/null 2>&1
  echo -e "${GREEN}✔ TLS 1.3${NC}"
}

create_origin_certificate() {
  CERT_FILE="${CERT_DIR}/${DOMAIN}_origin_cert.pem"
  KEY_FILE="${CERT_DIR}/${DOMAIN}_origin_key.pem"
  
  if [ -f "${CERT_FILE}" ] && [ -f "${KEY_FILE}" ]; then
    echo -e "${GREEN}✔ Origin certificates exist${NC}"
    read -rp "❓ Create new certificate? (y/n): [n]" CREATE_NEW
    [[ ! "$CREATE_NEW" =~ ^[Yy]$ ]] && return
  fi
  
  echo -e "${BLUE}🔐 Creating origin certificate...${NC}"
  
  TEMP_KEY="${CERT_DIR}/temp-key.pem"
  TEMP_CSR="${CERT_DIR}/temp.csr"
  
  openssl genrsa -out "${TEMP_KEY}" 2048 2>/dev/null
  openssl req -new -key "${TEMP_KEY}" -subj "/CN=${DOMAIN}" \
      -addext "subjectAltName = DNS:${DOMAIN}, DNS:*.${DOMAIN}" \
      -out "${TEMP_CSR}" 2>/dev/null
  
  CSR_CONTENT=""
  while IFS= read -r line; do
    CSR_CONTENT="${CSR_CONTENT}${line}\\n"
  done < "${TEMP_CSR}"
  
  CERT_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/certificates" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
       --data '{
         "csr": "'"${CSR_CONTENT}"'",
         "hostnames": ["'"${DOMAIN}"'", "*.'"${DOMAIN}"'"],
         "request_type": "origin-rsa",
         "requested_validity": 5475
       }')
  
  if echo "$CERT_RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
    CERTIFICATE=$(echo "$CERT_RESPONSE" | jq -r '.result.certificate')
    mv "${TEMP_KEY}" "${KEY_FILE}"
    echo "$CERTIFICATE" > "${CERT_FILE}"
    rm -f "${TEMP_CSR}"
    echo -e "${GREEN}✔ Certificate created${NC}"
  else
    echo -e "${RED}❌ Certificate creation failed${NC}"
    rm -f "${TEMP_KEY}" "${TEMP_CSR}"
    [ -f "${CERT_FILE}" ] && echo -e "${YELLOW}⚠️ Using existing files${NC}" || exit 1
  fi
}

create_tunnel() {
  COMPOSE_FILE="./remotefalcon/compose.yaml"
  CLOUDFLARED_WAS_STOPPED=false

  # Fetch existing tunnels
  EXISTING_TUNNELS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

  # Build useful diagnostics (optional)
  TOTAL_TUNNELS=$(echo "$EXISTING_TUNNELS" | jq -r '.result | length // 0')
  ACTIVE_TUNNELS=$(echo "$EXISTING_TUNNELS" | jq -c '[.result[] | select(.deleted_at == null)]')
  TUNNEL_COUNT=$(echo "$ACTIVE_TUNNELS" | jq -r 'length // 0')

  if [ "$TUNNEL_COUNT" -gt 0 ]; then
    # choose most recently created active tunnel
    TUNNEL_ID=$(echo "$ACTIVE_TUNNELS" | jq -r 'sort_by(.created_at) | .[-1].id')
    echo -e "${GREEN}✔ Active tunnel exists${NC}"

    read -rp "❓ Recreate tunnel? (y/n): [n]" RECREATE
    if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
      if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${BLUE}🛑 Ensuring cloudflared is stopped...${NC}"
        sudo docker compose -f "$COMPOSE_FILE" down cloudflared 2>/dev/null && CLOUDFLARED_WAS_STOPPED=true
        sleep 3
      fi

      # Delete tunnel configurations (best-effort)
      echo -e "${BLUE}🗑️ Removing tunnel configuration...${NC}"
      curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
           -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" > /dev/null 2>&1

      # Now delete the tunnel
      echo -e "${BLUE}🗑️ Deleting tunnel...${NC}"
      DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}" \
           -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

      # If delete call returned success OR a specific known "already deleted" error
      if echo "$DELETE_RESPONSE" | jq -e '.success == true' > /dev/null 2>&1 || \
         echo "$DELETE_RESPONSE" | jq -e '.errors[]? | select(.code == 1003)' > /dev/null 2>&1; then
        echo -e "${GREEN}✔ Tunnel deleted (API reported success)${NC}"
        echo -e "${CYAN}  Waiting for deletion to propagate...${NC}"

        # Poll for verification up to N attempts, but only consider active tunnels (deleted_at == null)
        RETRIES=5
        SLEEP_SECS=3
        VERIFIED=false

        for i in $(seq 1 $RETRIES); do
          sleep $SLEEP_SECS

          VERIFY_TUNNELS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}" \
               -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

          VERIFY_ACTIVE_COUNT=$(echo "$VERIFY_TUNNELS" | jq -r '[.result[] | select(.deleted_at == null)] | length // 0')

          if [ "$VERIFY_ACTIVE_COUNT" -eq 0 ]; then
            VERIFIED=true
            break
          fi

          echo -e "${YELLOW}⚠️ Tunnel still appears active (attempt $i/$RETRIES), waiting...${NC}"
          # exponential backoff-ish
          SLEEP_SECS=$((SLEEP_SECS + 3))
        done

        if [ "$VERIFIED" = true ]; then
          echo -e "${GREEN}✔ Tunnel verified deleted${NC}"
        else
          # After retries, still active -> show helpful diagnostics and try cleanup if possible
          echo -e "${RED}❌ Tunnel deletion verification failed${NC}"
          echo -e "${YELLOW}⚠️ Cloudflare API returned success but an active tunnel record still exists${NC}"

          # try cloudflared cleanup if available and error suggests active connections could block deletion
          if command -v cloudflared &> /dev/null; then
            echo -e "${BLUE}🔧 Attempting cloudflared tunnel cleanup (best-effort)...${NC}"
            cloudflared tunnel cleanup "${TUNNEL_ID}" || true
            sleep 2

            # Try delete one more time
            DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}" \
                 -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

            # Re-check active count
            VERIFY_TUNNELS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}" \
                 -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
            VERIFY_ACTIVE_COUNT=$(echo "$VERIFY_TUNNELS" | jq -r '[.result[] | select(.deleted_at == null)] | length // 0')

            if [ "$VERIFY_ACTIVE_COUNT" -eq 0 ]; then
              echo -e "${GREEN}✔ Tunnel deleted after cleanup${NC}"
              VERIFIED=true
            fi
          fi

          if [ "$VERIFIED" != true ]; then
            echo -e "${CYAN}  Please manually delete tunnel '${TUNNEL_NAME}' from:${NC}"
            echo -e "${CYAN}  https://one.dash.cloudflare.com/networks/tunnels${NC}"
            read -rp "Press Enter after manually deleting the tunnel..."
            # Final verification
            FINAL_CHECK=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}" \
                 -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
            FINAL_ACTIVE_COUNT=$(echo "$FINAL_CHECK" | jq -r '[.result[] | select(.deleted_at == null)] | length // 0')

            if [ "$FINAL_ACTIVE_COUNT" -gt 0 ]; then
              echo -e "${RED}❌ Tunnel still exists. Cannot proceed.${NC}"
              exit 1
            fi
            echo -e "${GREEN}✔ Tunnel verified deleted${NC}"
          fi
        fi
      else
        # Delete API returned an error. Handle known error codes or display the error.
        ERROR_CODE=$(echo "$DELETE_RESPONSE" | jq -r '.errors[0].code // empty')
        if [ "$ERROR_CODE" = "1022" ]; then
          echo -e "${RED}❌ Tunnel has active connections${NC}"
          if command -v cloudflared &> /dev/null; then
            echo -e "${BLUE}🔧 Cleaning up connections...${NC}"
            cloudflared tunnel cleanup "${TUNNEL_ID}" || true
            sleep 2
            DELETE_RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}" \
                 -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
            if echo "$DELETE_RESPONSE" | jq -e '.success == true' > /dev/null 2>&1; then
              echo -e "${GREEN}✔ Tunnel deleted after cleanup${NC}"
            else
              echo -e "${RED}❌ Failed to delete tunnel after cleanup${NC}"
              echo "$DELETE_RESPONSE" | jq '.'
              exit 1
            fi
          else
            echo -e "${RED}❌ Cannot cleanup - cloudflared not found${NC}"
            exit 1
          fi
        else
          echo -e "${RED}❌ Failed to delete tunnel${NC}"
          echo "$DELETE_RESPONSE" | jq '.'
          exit 1
        fi
      fi
    else
      echo "$TUNNEL_ID" > "${CERT_DIR}/tunnel_id.txt"
      return
    fi
  fi
  
  echo -e "${BLUE}🚇 Creating tunnel...${NC}"
  
  TUNNEL_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
       --data '{"name": "'"${TUNNEL_NAME}"'", "tunnel_secret": "'"$(openssl rand -base64 32)"'"}')
  
  if echo "$TUNNEL_RESPONSE" | jq -e '.success' > /dev/null; then
    TUNNEL_ID=$(echo "$TUNNEL_RESPONSE" | jq -r '.result.id')
    TUNNEL_TOKEN=$(echo "$TUNNEL_RESPONSE" | jq -r '.result.token')
    
    echo "$TUNNEL_ID" > "${CERT_DIR}/tunnel_id.txt"
    echo "$TUNNEL_TOKEN" > "${CERT_DIR}/tunnel_token.txt"
    update_tunnel_token "${TUNNEL_TOKEN}"
    
    echo -e "${GREEN}✔ Tunnel created${NC}"
    
    if [ "$CLOUDFLARED_WAS_STOPPED" = true ] && [ -f "$COMPOSE_FILE" ]; then
      sudo docker compose -f "$COMPOSE_FILE" up -d cloudflared 2>/dev/null
      echo -e "${GREEN}✔ Cloudflared restarted${NC}"
    fi
  else
    echo -e "${RED}❌ Tunnel creation failed${NC}"
    echo -e "${YELLOW}Error details:${NC}"
    echo "$TUNNEL_RESPONSE" | jq '.'
    exit 1
  fi
}

configure_tunnel_routes() {
  echo -e "${BLUE}🔧 Configuring tunnel routes...${NC}"
  
  TUNNEL_ID=$(cat "${CERT_DIR}/tunnel_id.txt")
  
  CONFIG_JSON='{
    "config": {
      "ingress": [
        {
          "hostname": "'"${DOMAIN}"'",
          "service": "https://nginx",
          "originRequest": {
            "originServerName": "*.'"${DOMAIN}"'",
            "http2Origin": true,
            "noTLSVerify": false
          }
        },
        {
          "hostname": "*.'"${DOMAIN}"'",
          "service": "https://nginx",
          "originRequest": {
            "originServerName": "*.'"${DOMAIN}"'",
            "http2Origin": true,
            "noTLSVerify": false
          }
        },
        {
          "service": "https://nginx"
        }
      ]
    }
  }'
  
  curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
       --data "${CONFIG_JSON}" > /dev/null
  
  echo -e "${GREEN}✔ Routes configured${NC}"
}

add_tunnel_dns() {
  echo -e "${BLUE}🌐 Adding DNS records...${NC}"
  
  TUNNEL_ID=$(cat "${CERT_DIR}/tunnel_id.txt")
  TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"
  
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
       --data '{"type": "CNAME", "name": "@", "content": "'"${TUNNEL_CNAME}"'", "ttl": 1, "proxied": true}' > /dev/null
  echo -e "${GREEN}✔ Root domain record${NC}"
  
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
       -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
       --data '{"type": "CNAME", "name": "*", "content": "'"${DOMAIN}"'", "ttl": 1, "proxied": true}' > /dev/null
  echo -e "${GREEN}✔ Wildcard record${NC}"
}

print_summary() {
  echo
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}🎉 SETUP COMPLETE!${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo
  echo -e "${BLUE}📋 Configuration Summary:${NC}"
  echo -e "${CYAN}  Domain: ${DOMAIN}${NC}"
  echo -e "${CYAN}  Tunnel Name: ${TUNNEL_NAME}${NC}"
  TUNNEL_ID=$(cat "${CERT_DIR}/tunnel_id.txt" 2>/dev/null || echo "N/A")
  echo -e "${CYAN}  Tunnel ID: ${TUNNEL_ID}${NC}"
  echo
  echo -e "${BLUE}🌐 DNS Records Created:${NC}"
  echo -e "${CYAN}  - CNAME @ → ${TUNNEL_ID}.cfargotunnel.com (proxied)${NC}"
  echo -e "${CYAN}  - CNAME * → ${DOMAIN} (proxied)${NC}"
  echo
  echo -e "${BLUE}📁 Files created in ${CERT_DIR}:${NC}"
  echo -e "${CYAN}  - ${DOMAIN}_origin_cert.pem (Origin Certificate)${NC}"
  echo -e "${CYAN}  - ${DOMAIN}_origin_key.pem (Private Key)${NC}"
  echo -e "${CYAN}  - tunnel_id.txt (Tunnel ID)${NC}"
  echo -e "${CYAN}  - tunnel_token.txt (Tunnel Token)${NC}"
  echo
  echo -e "${BLUE}📝 Updated ${ENV_FILE}:${NC}"
  echo -e "${CYAN}  - DOMAIN=${DOMAIN}${NC}"
  echo -e "${CYAN}  - TUNNEL_TOKEN=<token>${NC}"
  echo
  echo -e "${YELLOW}⚠️ IMPORTANT: Keep certificate and token files secure!${NC}"
  echo
  echo -e "${GREEN}✨ Setup complete!${NC}"
}

main() {
  check_requirements
  read_env_file
  get_user_input
  get_account_id
  add_domain_to_cloudflare
  
  echo
  echo -e "${BLUE}⚙️ Starting configuration...${NC}"
  echo
  
  delete_conflicting_records
  configure_ssl
  create_origin_certificate
  create_tunnel
  configure_tunnel_routes
  add_tunnel_dns
  
  print_summary
}

main