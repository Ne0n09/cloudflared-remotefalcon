#!/bin/bash

# Check if docker is installed and ask to download and install it if not (For Ubuntu and Debian).
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

### Download compose.yaml and default.conf if they do not exist. Ask if they should be downloaded

# compose.yaml download
if [ ! -f compose.yaml ]; then
        read -p "The compose.yaml file does not exist, would you like to download it? (y/n) [y]: " downloadcompose
        downloadcompose=${downloadcompose:-y}
        echo $downloadcompose

        if [[ "$downloadcompose" == "y" ]]; then
                echo "Downloading compose.yaml..."
                        curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/no-published-ports/compose.yaml
                echo "Done."
        fi
fi

# default.conf download
if [ ! -f default.conf ]; then
        read -p "The nginx default.conf file does not exist, would you like to download it? (y/n) [y]: " downloadnginxconf
        downloadnginxconf=${downloadnginxconf:-y}
        echo $downloadnginxconf

        if [[ "$downloadnginxconf" == "y" ]]; then
                echo "Downloading default.conf..."
                curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/no-published-ports/default.conf
                echo "Done."
        fi
fi

# Print existing .env file, if it exists, otherwise download the default .env file
echo "Checking for existing .env file for environmental variables..."
if [ -f .env ]; then
        echo "Source .env exists!"
        echo "Printing current .env variables:"
        echo
        echo "--------------------------------"
        # Load the existing .env variables to allow for auto-completion
        while IFS='=' read -rs line; do
                # Ignore any comment lines and empty lines
                if [[ $line == \#* || -z "$line" ]]; then
                        continue
                fi

                # Split the line into key and value
                key="${line%%=*}"
                value="${line#*=}"

                export "$key"="$value"
                echo "$key=$value"
        done < .env
        echo "--------------------------------"
else
        echo "Source .env DOES not exist!"
        echo "Downloading default .env..."
        curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/.env
        echo "Done."
        echo "Reading values from default .env"
        echo
        echo "--------------------------------"
        # Load the .env variables from the default .env to allow for auto-completion
        while IFS='=' read -rs line; do
                # Ignore any comment lines and empty lines
                if [[ $line == \#* || -z "$line" ]]; then
                        continue
                fi

                # Split the line into key and value
                key="${line%%=*}"
                value="${line#*=}"

                export "$key"="$value"
                echo "$key=$value"
        done < .env
        echo "--------------------------------"
fi

# Ask to configure .env values
read -p "Update the .env file variables? (y/n) [n]: " configureenv
configureenv=${configureenv:-n}
echo $configureenv
if [[ "$configureenv" == "y" ]]; then
        ### Configuration walkthrough questions. Questions will pull existing or default values from the sourced .env file
        echo
        echo "Answer the following questions to update your compose .env variables."
        echo "Press enter to accept the existing values that are between the brackets [ ]."
        echo "You will be asked to confirm the changes before the file is modified."
        echo
        read -p "Enter your Cloudflare tunnel token: [$TUNNEL_TOKEN]: " tunneltoken
        tunneltoken=${tunneltoken:-$TUNNEL_TOKEN}
        echo
        read -p "Enter your domain name, example: yourdomain.com: [$DOMAIN]: " domain
        domain=${domain:-$DOMAIN}
        echo
        read -p "Enter a random value for viewer JWT key: [$VIEWER_JWT_KEY]: " viewerjwtkey
        viewerjwtkey=${viewerjwtkey:-$VIEWER_JWT_KEY}
        echo
        # Removing this again to avoid issues - .env can be manually edited if you have ACM and want a 3 part domain.
        #echo "Enter the number of parts in your hostname. For example, domain.com would be two parts ('domain' and 'com'), and sub.domain.com would be 3 parts ('sub', 'domain', and 'com')"
        #read -p "Cloudflare free only supports two parts for wildcard domains without Advanced Certicate Manager(\$10/month): [$HOSTNAME_PARTS]: " hostnameparts
        #hostnameparts=${hostnameparts:-$HOSTNAME_PARTS}
        #echo
        hostnameparts=2
        read -p "Enable auto validate email? While set to 'true' anyone can create a viewer page account on your site (true/false): [$AUTO_VALIDATE_EMAIL]: " autovalidateemail
        autovalidateemail=${autovalidateemail:-$AUTO_VALIDATE_EMAIL}
        echo

        # Ask if Cloudflare origin certificates should be updated. This will create the cert/key in the current directory and append the domain name to the beginning of the file name
        read -p "Update origin certificates? (y/n) [n]: " updatecerts
        updatecerts=${updatecerts:-n}
        echo $updatecerts
        if [[ "$updatecerts" == "y" ]]; then
                read -p "Press any key to open nano to paste the origin certificate. Ctrl+X, y, and Enter to save."
                nano ${domain}_origin_cert.pem

                read -p "Press any key to open nano to paste the origin private key. Ctrl+X, y, and Enter to save."
                nano ${domain}_origin_key.pem
        fi
        echo

        # Ask if analytics env variables should be set for PostHog and Google Analytics
        read -p "Update analytics variables? (y/n) [n]: " updateanalytics
        updateanalytics=${updateanalytics:-n}
        echo $updateanalytics
        if [[ "$updateanalytics" == "y" ]]; then
                read -p "Enter your PostHog key - https://posthog.com/: [$PUBLIC_POSTHOG_KEY]: " publicposthogkey

                read -p "Enter your Google Analytics Measurement ID - https://analytics.google.com/: [$GA_TRACKING_ID]: " gatrackingid
        fi

        publicposthogkey=${publicposthogkey:-$PUBLIC_POSTHOG_KEY}
        gatrackingid=${gatrackingid:-$GA_TRACKING_ID}
        echo

        # Ask if SOCIAL_META variable should be updated
        read -p "Update social meta tag? (y/n) [n]: " updatemeta
        updatemeta=${updatemeta:-n}
        echo $updatemeta
        if [[ "$updatemeta" == "y" ]]; then
                echo "See the RF docs for details on the SOCIAL_META tag:"
                echo "https://docs.remotefalcon.com/docs/developer-docs/running-it/digitalocean-droplet?fbclid=IwY2xjawFX_bZleHRuA2FlbQIxMQABHcqsd9FjidxVKTUXxqYRmE-9K9rysi1dIU11x5sZW_kNdO_az9ZrtHRn3g_aem_T4XwWEZw7KronYDs74wGdw#update-docker-composeyaml"
                echo
                echo "Update SOCIAL_META tag or leave as default - Enter on one line only"
                echo
                read "-p [$SOCIAL_META]: " socialmeta

        socialmeta=${socialmeta:-$SOCIAL_META}
        echo

        # May implement some container upgrade logic in the future
        rfcontainerbuilddate=$RF_CONTAINER_BUILD_DATE
        nginxversion=$NGINX_VERSION
        mongoversion=$MONGO_VERSION
        cloudflaredversion=$CLOUDFLARED_VERSION

        # Print all answers before asking to update the .env file
        echo
        echo "Please confirm the values below are correct:"
        echo
        echo "--------------------------------"
        echo "TUNNEL_TOKEN=$tunneltoken"
        echo "DOMAIN=$domain"
        echo "VIEWER_JWT_KEY=$viewerjwtkey"
        echo "HOSTNAME_PARTS=$hostnameparts"
        echo "AUTO_VALIDATE_EMAIL=$autovalidateemail"
        echo "NGINX_CONF=$NGINX_CONF"
        echo "NGINX_CERT=./${domain}_origin_cert.pem"
        echo "NGINX_KEY=./${domain}_origin_key.pem"
        echo "HOST_ENV=$HOST_ENV"
        echo "VERSION=$VERSION"
        echo "GOOGLE_MAPS_KEY=$GOOGLE_MAPS_KEY"
        echo "PUBLIC_POSTHOG_KEY=$publicposthogkey"
        echo "PUBLIC_POSTHOG_HOST=$PUBLIC_POSTHOG_HOST"
        echo "GA_TRACKING_ID=$gatrackingid"
        echo "CLIENT_HEADER=$CLIENT_HEADER"
        echo "SENGRID_KEY=$SENGRID_KEY"
        echo "GITHUB_PAT=$GITHUB_PAT"
        echo "SOCIAL_META=$socialmeta"
        echo "RF_CONTAINER_BUILD_DATE=$rfcontainerbuilddate"
        echo "NGINX_VERSION=$nginxversion"
        echo "MONGO_VERSION=$mongoversion"
        echo "CLOUDFLARED_VERSION=$cloudflaredversion"
        echo "--------------------------------"
        echo

        read -p "Update the .env file with the above values? (y/n) [n]: " updateenv
        updateenv=${updateenv:-n}
        echo $updateenv

        # Write the variables to the .env file if ansewr is y
        if [[ "$updateenv" == "y" ]]; then
                echo "Writing variables to .env file..."
                echo "TUNNEL_TOKEN=$tunneltoken" > .env
                echo "DOMAIN=$domain" >> .env
                echo "VIEWER_JWT_KEY=$viewerjwtkey" >> .env
                echo "HOSTNAME_PARTS=$hostnameparts" >> .env
                echo "AUTO_VALIDATE_EMAIL=$autovalidateemail" >> .env
                echo "NGINX_CONF=$NGINX_CONF" >> .env
                echo "NGINX_CERT=./${domain}_origin_cert.pem" >> .env
                echo "NGINX_KEY=./${domain}_origin_key.pem" >> .env
                echo "HOST_ENV=$HOST_ENV" >> .env
                echo "VERSION=$VERSION" >> .env
                echo "GOOGLE_MAPS_KEY=$GOOGLE_MAPS_KEY" >> .env
                echo "PUBLIC_POSTHOG_KEY=$publicposthogkey" >> .env
                echo "PUBLIC_POSTHOG_HOST=$PUBLIC_POSTHOG_HOST" >> .env
                echo "GA_TRACKING_ID=$gatrackingid" >> .env
                echo "CLIENT_HEADER=$CLIENT_HEADER" >> .env
                echo "SENGRID_KEY=$SENGRID_KEY" >> .env
                echo "GITHUB_PAT=$GITHUB_PAT" >> .env
                echo "SOCIAL_META=$SOCIAL_META" >> .env
                echo "RF_CONTAINER_BUILD_DATE=$rfcontainerbuilddate" >> .env
                echo "NGINX_VERSION=$nginxversion" >> .env
                echo "MONGO_VERSION=$mongoversion" >> .env
                echo "CLOUDFLARED_VERSION=$cloudflaredversion" >> .env
                echo "Writing variables to .env file completed!"
                echo
        else
                echo "Variables were not updated! No changes were made to the .env file"
                echo
        fi
fi

# Ask to start new containers or restart/rebuild existing containers
read -p "Start new containers or restart/rebuild existing containers to apply any changes to the .env file? (y/n) [n]: " restart
restart=${restart:-n}
echo $restart

if [[ "$restart" == "y" ]]; then
        echo "You may be asked to enter your password to run 'sudo' commands"
        echo "Bringing containers down with sudo docker compose down:"
        sudo docker compose down
        echo
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
                echo "Attempting to remove plugins-api image..."
                sudo docker image remove plugins-api
                echo "Done removing images"
        fi
        echo
        echo "Bringing containers up with sudo docker compose up -d"
        echo
        sudo docker compose up -d
        echo
        echo "Sleeping 20 seconds before running 'sudo docker ps' to verify the status of all containers"
        sleep 20s
        echo
        echo "sudo docker ps"
        sudo docker ps
        echo
        echo "Done. Verify that all containers show 'Up'. If not, check logs with 'sudo docker logs <container_name>' or try 'sudo docker compose up -d'"
fi
