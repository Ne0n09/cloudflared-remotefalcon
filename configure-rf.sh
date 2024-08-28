#!/bin/bash

# Check if docker is installed and ask to download and install it if not.
if [ ! -x "$(command -v docker)" ]; then
        read -p "Docker is not installed, would you like to install it? (y/n) [y]: " downloaddocker
        downloaddocker=${downloaddocker:-y}
        echo $downloaddocker

        if [[ "$downloaddocker" == "y" ]]; then
                echo "Installing docker... you may need to enter your password for the 'sudo' command"
                # Get OS distribution
                source /etc/os-release
                case $ID in
                ubuntu)
                        echo "Installing Docker for Ubuntu..."
                        sudo apt-get update && sudo apt-get install ca-certificates curl && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                        echo "Docker installation for Ubuntu complete!"
                ;;
                debian)
                        echo "Installing Docker for Debian.."
                        sudo apt-get update && sudo apt-get install ca-certificates curl && sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                        echo "Docker installation for Debian complete!"
                ;;
                *) echo "Distribution is not supported by this script! Please install Docker manually."
                ;;
                esac
        fi
fi

# Download .env, default.conf, and compose.yaml if they do not exist. Ask if they should be downloaded
if [ ! -f compose.yaml ]; then
        read -p "The compose.yaml file does not exist, would you like to download it? (y/n) [y]: " downloadcompose
        downloadcompose=${downloadcompose:-y}
        echo $downloadcompose

        if [[ "$downloadcompose" == "y" ]]; then
                echo "Downloading compose.yaml..."
                curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/compose.yaml
                echo "Done."
        fi
fi

if [ ! -f default.conf ]; then
        read -p "The nginx default.conf file does not exist, would you like to download it? (y/n) [y]: " downloadnginxconf
        downloadnginxconf=${downloadnginxconf:-y}
        echo $downloadnginxconf

        if [[ "$downloadnginxconf" == "y" ]]; then
                echo "Downloading default.conf..."
                curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/default.conf
                echo "Done."
        fi
fi

# Print existing .env file variables, if it exists
if [ -f .env ]; then
        echo "Source .env exists!"
        echo "Printing current values:"
        echo
        cat .env
        echo
        # Load the existing .env variables to allow for auto-completion
        source .env
else
        echo "Source .env DOES not exist!"
        echo "Setting some default values..."
        VIEWER_JWT_KEY="123456"
        HOSTNAME_PARTS="2"
        AUTO_VALIDATE_EMAIL="true"
        CLIENT_HEADER="CF-Connecting-IP"
fi

echo "Answer the following questions to update your compose .env variables."
echo "Press enter to accept the existing values that are between the brackets [ ]."
echo "You will be asked to confirm the changes before the file is modified."
echo
read -p "Enter your Cloudflare tunnel token: [$TUNNEL_TOKEN]: " tunneltoken
tunneltoken=${tunneltoken:-$TUNNEL_TOKEN}

read -p "Enter your domain name, example: yourdomain.com: [$DOMAIN]: " domain
domain=${domain:-$DOMAIN}

read -p "Enter a random value for viewer JWT key: [$VIEWER_JWT_KEY]: " viewerjwtkey
viewerjwtkey=${viewerjwtkey:-$VIEWER_JWT_KEY}

# Removed since Free CF does not allot multi level subdomains without paying
#read -p "Enter the number of parts in your hostname. For example, domain.com would be two parts ('domain' and 'com'), and sub.domain.com would be 3 parts ('sub', 'domain', and 'com'): [$HOSTNAME_PARTS]: " hostnameparts
#hostnameparts=${hostnameparts:-$HOSTNAME_PARTS}
hostnameparts=$HOSTNAME_PARTS

read -p "Enable auto validate email? (true/false): [$AUTO_VALIDATE_EMAIL]: " autovalidateemail
autovalidateemail=${autovalidateemail:-$AUTO_VALIDATE_EMAIL}

read -p "Update origin certificates? (y/n) [n]: " updatecerts
updatecerts=${updatecerts:-n}
echo $updatecerts
if [[ "$updatecerts" == "y" ]]; then
        read -p "Press any key to open nano to paste the origin certificate. Ctrl+X and y to save."
        nano ${domain}_origin_cert.pem

        read -p "Press any key to open nano to paste the origin private key. Ctrl+X and y to save."
        nano ${domain}_origin_key.pem
fi

echo
echo "Please confirm the variables below are correct:"
echo "TUNNEL_TOKEN=$tunneltoken"
echo "DOMAIN=$domain"
echo "VIEWER_JWT_KEY=$viewerjwtkey"
#echo "HOSTNAME_PARTS=$hostnameparts"
echo "AUTO_VALIDATE_EMAIL=$autovalidateemail"
echo "NGINX_CERT=./${domain}_origin_cert.pem"
echo "NGINX_KEY=./${domain}_origin_key.pem"

read -p "Update the .env file with the above variables? (y/n): " updateenv

if [[ "$updateenv" == "y" ]]; then
        echo "Writing variables to .env file..."
        echo "Writing TUNNEL_TOKEN=$tunneltoken"
        echo "TUNNEL_TOKEN=$tunneltoken" > .env
        echo "Writing DOMAIN=$domain"
        echo "DOMAIN=$domain" >> .env
        echo "Writing VIEWER_JWT_KEY=$viewerjwtkey"
        echo "VIEWER_JWT_KEY=$viewerjwtkey" >> .env
#        echo "Writing HOSTNAME_PARTS=$hostnameparts"
        echo "HOSTNAME_PARTS=$hostnameparts" >> .env
        echo "Writing AUTO_VALIDATE_EMAIL=$autovalidateemail"
        echo "AUTO_VALIDATE_EMAIL=$autovalidateemail" >> .env
        echo "Writing NGINX_CONF=./default.conf"
        echo "NGINX_CONF=./default.conf" >> .env
        echo "Writing NGINX_CERT=./${domain}_origin_cert.pem"
        echo "NGINX_CERT=./${domain}_origin_cert.pem" >> .env
        echo "Writing NGINX_KEY=./${domain}_origin_key.pem"
        echo "NGINX_KEY=./${domain}_origin_key.pem" >> .env
        echo "HOST_ENV=prod" >> .env
        echo "VERSION=1.0.0" >> .env
        echo "GOOGLE_MAPS_KEY=" >> .env
        echo "PUBLIC_POSTHOG_KEY=" >> .env
        echo "GA_TRACKING_ID=1" >> .env
        echo "CLIENT_HEADER=CF-Connecting-IP" >> .env
        echo "Writing variables to .env file completed!"
        echo
else
        echo "Variables were not updated! No changes were made to the .env file"
        echo
fi
# Ask to start/restart the containers
read -p "Would you like to start new containers or bring existing containers down and bring them back up to apply the .env file? (y/n): " restart
echo $restart
if [[ "$restart" == "y" ]]; then
        echo "You may be asked to enter your password to run 'sudo' commands"
        echo "Bringing containers down with sudo docker compose down"
        sudo docker compose down
        # Ask to remove existing images
        read -p "Would you also like to remove and rebuild existing Remote Falcon images? (y/n) [n]: " rebuild
        rebuild=${rebuild:-n}
        echo $rebuild
        if [[ "$rebuild" == "y" ]]; then
                echo "Attempting to remove Remote Falcon images..."
                echo "Attempting to remove ui image..."
                sudo docker image remove ui
                echo "Attempting to remove viewer image..."
                sudo docker image remove viewer
                echo "Attempting to remove control-panel image..."
                sudo docker image remove control-panel
                echo "Done removing images"
        fi
        echo "Bringing containers back up with sudo docker compose up -d"
        sudo docker compose up -d
        echo "Sleeping 20 seconds before running 'sudo docker ps' to verify the status of all containers"
        sleep 20s
        echo "sudo docker ps"
        sudo docker ps
        echo "Done. Verify that all containers show 'Up'"
fi
