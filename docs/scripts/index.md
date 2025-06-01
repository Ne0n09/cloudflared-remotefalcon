**WORK IN PROGRESS**

## Bash Scripts Details

=== "Configure RF"

    - This script is used for the initial setup and configuration of [cloudflared-remotefalcon](https://github.com/Ne0n09/cloudflared-remotefalcon/tree/main).

    - The script guides on setting the required and some optional [.env](../architecture/files.md#env) variables.

    - The script can be re-run to call the update_rf_containers, update_containers, and health_check scripts.

    ```sh title="Run the configure-rf script"
    ./configure-rf.sh
    ```

    ```sh title="Example output on first run"
    ⚙️ Running RF configuration script...
    Working in directory: /home/user/remotefalcon
    Found existing .env at /home/user/remotefalcon/.env.
    🔍 Parsing current .env variables:
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔹 TUNNEL_TOKEN=cloudflare_token
    🔹 DOMAIN=your_domain.com
    🔹 VIEWER_JWT_KEY=123456
    🔹 USER_JWT_KEY=123456
    🔹 HOSTNAME_PARTS=2
    🔹 AUTO_VALIDATE_EMAIL=true
    🔹 NGINX_CONF=./default.conf
    🔹 NGINX_CERT=./origin_cert.pem
    🔹 NGINX_KEY=./origin_key.pem
    🔹 HOST_ENV=prod
    🔹 VERSION=1.0.0
    🔹 GOOGLE_MAPS_KEY=
    🔹 PUBLIC_POSTHOG_KEY=
    🔹 PUBLIC_POSTHOG_HOST=https://us.i.posthog.com
    🔹 GA_TRACKING_ID=1
    🔹 MIXPANEL_KEY=
    🔹 CLIENT_HEADER=CF-Connecting-IP
    🔹 SENDGRID_KEY=
    🔹 GITHUB_PAT=
    🔹 SOCIAL_META=<meta property='og:url' content='https://remotefalcon.com/'/><meta property='og:title' content='Remote Falcon'/><meta property='og:description' content='Create a custom website where viewers can request or vote for sequences to watch on your light show.'/><meta property='og:image' content='https://remotefalcon.com/jukebox.png'/>
    🔹 SEQUENCE_LIMIT=200
    🔹 MONGO_PATH=/home/mongo-volume
    🔹 MONGO_INITDB_ROOT_USERNAME=root
    🔹 MONGO_INITDB_ROOT_PASSWORD=root
    🔹 MONGO_URI=mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@mongo:27017/remote-falcon?authSource=admin
    🔹 MINIO_PATH=/home/minio-volume
    🔹 MINIO_ROOT_USER=12345678
    🔹 MINIO_ROOT_PASSWORD=12345678
    🔹 S3_ENDPOINT=http://minio:9000
    🔹 S3_ACCESS_KEY=123456
    🔹 S3_SECRET_KEY=123456
    🔹 OTEL_URI=
    🔹 OTEL_OPTS=
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ❓ Change the .env file variables? (y/n) [n]:
    ```

=== "Update RF Containers"

    - This script will update your Remote Falcon containers to the latest available commit on the [Remote Falcon Github](https://github.com/Remote-Falcon).
    
    - The [compose.yaml](../architecture/files.md#composeyaml) build context hash is updated to the latest commit for the container.

    - The image tag for the container is updated in the compose.yaml to the short-hash:
    ```yaml linenums="50" hl_lines="3 6"
      plugins-api:
        build:
          context: https://github.com/Remote-Falcon/remote-falcon-plugins-api.git#cc1593aab27dc195a4c55b5b1410ddc06e96a60c
          args:
            - OTEL_OPTS=${OTEL_OPTS}
        image: plugins-api:cc1593a
        container_name: plugins-api
    ```

    - A backup of the compose.yaml is created when any of the containers are updated.

    - The script accepts two arguments:

        1. [dry-run|auto-apply|interactive]

            - `dry-run`: Displays if any updates are available or if up to date.

            - `auto-apply`: Automatically update all RF containers if any updates are found.

            - `interactive/no argument`: Display if update is available and prompt for confirmation before updating each container.

        2. [health]

            - Add `health` after the first argument to automatically run the health_check script.

    ```sh title="update_rf_containers script syntax examples" 
    ./update_rf_containers.sh [dry-run|auto-apply|interactive] [health]
    ./update_rf_containers.sh
    ./update_rf_containers.sh dry-run health
    ./update_rf_containers.sh auto-apply
    ```

    ```sh title="Example output on first run of ./update_rf_containers.sh"
    ⚙️ Checking for Remote Falcon container updates...
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: external-api
    ⚠️ No context hash found for external-api; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: f7e09fe - Latest commit: f7e09fe74b8e064867795cda080da8c8d665ddec
    📜 external-api Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-external-api/commits/main
    ❓ Update external-api to f7e09fe? (y/n): y
    ✔ Backed up /home/user/remotefalcon/compose.yaml to /home/user/remotefalcon-backups/compose.yaml.backup-2025-06-01_11-46-02
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: ui
    ⚠️ No context hash found for ui; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: cb19864 - Latest commit: cb19864c25d42fd49aa4ec41cbe4f0af36497458
    📜 ui Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-ui/commits/main
    ❓ Update ui to cb19864? (y/n): y
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: plugins-api
    ⚠️ No context hash found for plugins-api; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: cc1593a - Latest commit: cc1593aab27dc195a4c55b5b1410ddc06e96a60c
    📜 plugins-api Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-plugins-api/commits/main
    ❓ Update plugins-api to cc1593a? (y/n): y
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: viewer
    ⚠️ No context hash found for viewer; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: b7cfb2d - Latest commit: b7cfb2d54ad44264df5d04148d1bcea2bb8bcb34
    📜 viewer Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-viewer/commits/main
    ❓ Update viewer to b7cfb2d? (y/n): y
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: control-panel
    ⚠️ No context hash found for control-panel; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: e6c110c - Latest commit: e6c110c38fb032f9399e841e3ef704e96b7b8ba9
    📜 control-panel Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-control-panel/commits/main
    ❓ Update control-panel to e6c110c? (y/n): y
    🛠️ Building containers with updated tags...
    ```

=== "Update Containers"

    This script updates the non-RF containers

    ```sh title="update_containers.sh" linenums="1" hl_lines="3"
    # To update Non-Remote Falcon containers run this script
    # 1st argument: container name or all
    # 2nd argument: dry-run - checks and displays updates only, auto-apply will automatically apply any updates, interactive prompts for update
    # 3rd argument: health - add this at the end to automatically run the health check script after update
    ./update_containers.sh [all|mongo|minio|nginx|cloudflared] [dry-run|auto-apply|interactive] [health]
    ```

=== "Health Check"

    This script will perform a 'health check' and display issues that are found.

    ```sh title="update_containers.sh" linenums="1" hl_lines="3"
    # Run a health check directly:
    
    ./health_check.sh
    ```

=== "Generate JWT"

    This is to be able to make use of the External API.

    Assists with getting your API access token and secret key from your Remote Falcon show in the MongoDB database if you don't have email configured(Sendgrid seems impossible to get an account created). 

    Then the script generates a JWT for you to use.

    ```sh title="generate_jwt.sh" linenums="1" hl_lines="3"
    # Retrieves external API access info and generates JWT:
    
    ./generate_jwt.sh
    ```

=== "Make Admin"

    This script will display shows that have admin access and allow you to toggle admin access when the show subdomain is passed as an argument.

    Run the script with no arguments to display currently configured showRole(USER/ADMIN).

    This basically lets you see and edit MongoDB information from within Remote Falcon.

    ```sh title="make_admin.sh" linenums="1" hl_lines="3"
    # ./make_admin.sh [yoursubdomain]:
    
    ./make_admin.sh
    ```

=== "MinIO Init"

    This script will configure MinIO. Minio is a lightweight object storage server.

    The script is called when 'configure-rf.sh' is run and if certain default values are found in the .env file and is pretty much a hands-off configuration.

    The minio container is configured for local direct access to the control-panel container.

    This lets you use the Image Hosting tab in the Control Panel which allows you to self host your viewer page images.

    The script can be run again manually with no ill-effects to ensure MinIO is configured properly.

    ```sh title="minio_init.sh" linenums="1" hl_lines="3"
    # ./minio_init.sh:
    
    ./minio_init.sh
    ```

=== "Shared Functions"

    This is a helper script for functions that are re-used across the other scripts. 