**WORK IN PROGRESS**

## Bash Scripts Details

=== "Configure RF"

    Download and run this to walk through the .env configuration and initial container updates.

    ```sh title="configure-rf.sh" linenums="1" hl_lines="3"
    # To run the script

    ./configure-rf.sh
    ```

=== "Update RF Containers"

    This script will update your Remote Falcon containers to the latest available commit on the Remote Falcon Github by updating the compose.yaml build context hash and also tag the image that is built to the short-hash.

    ```sh title="update_rf_containers.sh" linenums="1" hl_lines="3"
    # To update Remote Falcon containers run this script
    
    ./update_rf_containers.sh [dry-run|auto-apply|interactive] [health]
    ```

=== "Update Containers"

    This script updates the non-RF containers

    ```sh title="update_containers.sh" linenums="1" hl_lines="3"
    # To update Non-Remote Falcon containers run this script
    
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
    
    ./make_admin.sh
    ```

=== "Shared Functions"

    This is a helper script for functions that are re-used across the other scripts. 