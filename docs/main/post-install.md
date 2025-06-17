## Initial sign up and login

!!! note

    Ensure auto validate email was set to true to allow sign up on your Remote Falcon instance without email validation.

1. Go to `yourdomain.com` and click the Sign Up button

2. Create your account and sign in.

3. Click the gear icon in the top right -> Click Account Settings -> Click Account

4. Click the :material-content-copy: button to copy your `Show Token`.

## Update the FPP plugin settings

1. In FPP go to Content Setup -> Remote Falcon

2. Enter your `Show Token` from your self-hosted Remote Falcon account settings.

3. Update the *Plugins API Path* to your domain:

    !!! example "Example Plugins API Path"

          |                    | Developer Settings                                             |
          |--------------------|----------------------------------------------------------------|
          | Plugins API Path   | `https://yourdomain.com/remote-falcon-plugins-api`             |

4. Reboot FPP after applying the changes.

    !!! tip "Tip - Plugins API Path LAN access"

          If you have LAN access to your FPP player and Remote Falcon you can directly connect to the plugins-api container to avoid your FPP player from having to reach out to the internet and back:

          `http://ip.address.of.remote.falcon:8083/remote-falcon-plugins-api`

          |                    | Developer Settings                                                   |
          |--------------------|----------------------------------------------------------------------|
          | Plugins API Path   |   http://localip.address.of.remote.falcon:8083/remote-falcon-plugins-api  |

5. You can now continue with configuring your viewer page and other settings. Reference the [Remote Falcon Docs](https://docs.remotefalcon.com/docs/docs/welcome) if needed.

### FPP 9

FPP 9 has some extra steps due to the addition of [Apache CSP](https://github.com/FalconChristmas/fpp/blob/master/docs/ApacheContentSecurityPolicy.md).

You will have to manually add your site to the trusted list or the plugins page will not load with the custom *Plugins API Path*.

1. In FPP go to Help -> :fontawesome-solid-terminal: SSH Shell

2. Login. The default user and password is fpp/falcon.

3. Set the `DOMAIN` variable directly on the FPP shell to `https://yourdomain.com` OR `http://localip.address.of.remote.falcon:8083` if you're using LAN access. 

    Type or copy and paste it into the FPP shell.

    ```sh title="Example, set one of these on the FPP shell"
    DOMAIN=https://yourdomain.com
    DOMAIN=http://localip.address.of.remote.falcon:8083
    ```

4. Copy and paste the command below to add your site to the trusted list by:
    
    Right-clicking the FPP shell window -> *Paste from browser* -> paste the command -> Click OK -> Enter to run:
    ```sh title="Copy and past this to update Apache CSP with DOMAIN and to show the configuration"
    sudo /opt/fpp/scripts/ManageApacheContentPolicy.sh add connect-src $DOMAIN;/opt/fpp/scripts/ManageApacheContentPolicy.sh show
    ```

    ```sh title="Example command output of Apache CSP add and show" hl_lines="11"
    Domain 'http://localip.address.of.remote.falcon:8083' added under'connect-src'.
    CSP header generated.
    Apache configuration reloaded successfully.
    {                                                             
    "default-src": [],
    "img-src": [],
    "script-src": [],
    "style-src": [],
    "connect-src": [
        "https://remotefalcon.com",
        "http://localip.address.of.remote.falcon:8083"
    ],
    "object-src": []
    }
    ```

5. Now you should be able to update the plugin settings normally. If you still have issues try rebooting or power cycling your FPP device.

    !!!tip "Tip - Command to update both Apache CSP and Plugins API Path"

        You can substitute this command below for steps 3 and 4 above to update both the Apache CSP and the *Plugins API Path*.

        ```sh title="Example, set one of these on the FPP shell"
        DOMAIN=https://yourdomain.com
        DOMAIN=http://localip.address.of.remote.falcon:8083
        ```

        ```sh title="Command to update both Apache CSP and Plugins API Path"
        echo;echo "Adding '$DOMAIN' to Apache CSP...";sudo /opt/fpp/scripts/ManageApacheContentPolicy.sh add connect-src $DOMAIN;echo "Displaying currently configured domains for Apache CSP:";/opt/fpp/scripts/ManageApacheContentPolicy.sh show;echo "Updating Plugins API Path with '$DOMAIN'...";sed -i 's|^pluginsApiPath = ".*"|pluginsApiPath = "'$DOMAIN'/remote-falcon-plugins-api"|' media/config/plugin.remote-falcon;echo "Printing Remote Falcon Plugin configuration:";cat media/config/plugin.remote-falcon

        ```

        ```sh title="Example output" hl_lines="13 26"
        Adding 'http://localip.address.of.remote.falcon:8083' to Apache CSP...
        Domain 'http://localip.address.of.remote.falcon:8083' added under 'connect-src'.
        CSP header generated.
        Apache configuration reloaded successfully.
        Displaying currently configured domains for Apache CSP:
        {
        "default-src": [],
        "img-src": [],
        "script-src": [],
        "style-src": [],
        "connect-src": [
            "https://remotefalcon.com",
            "http://localip.address.of.remote.falcon:8083"
        ],
        "object-src": []
        }
        Updating Plugins API Path with 'http://localip.address.of.remote.falcon:8083'...
        Printing Remote Falcon Plugin configuration:
        pluginVersion = "2025.04.05.1"
        remotePlaylist = ""
        interruptSchedule = "false"
        remoteToken = ""
        requestFetchTime = "3"
        additionalWaitTime = "0"
        fppStatusCheckTime = "1"
        pluginsApiPath = "http://localip.address.of.remote.falcon:8083/remote-falcon-plugins-api"
        verboseLogging = "false"
        remoteFalconListenerEnabled = "true"
        remoteFalconListenerRestarting = "false"
        init = "true"
        ```

## Remote Falcon Image hosting

If [minio-init](../scripts/index.md#__tabbed_1_7){ data-preview } script ran successfully and configured MinIO then you are able to make use of the Image Hosting page in the Control Panel.

If it is not configured succesfully, you will be greeted with a blank white page after attempting to upload an image.

Otherwise, uploading images should display a `image-name.png uploaded successfully.` message and you will see it in the list of images such as below:

| Preview | Image URL                                                                                       | Actions |
|---------|--------------------------------------------------------------------------------------------------|---------|
| :material-image-broken: | `https://remote-falcon-images.nyc3.cdn.digitaloceanspaces.com/yourshowname/linkedin.png` | :octicons-trash-16:     |
| :material-image-broken: | `https://remote-falcon-images.nyc3.cdn.digitaloceanspaces.com/yourshowname/sl3gtwl.png`  | :octicons-trash-16:     |

!!!warning

    Ignore the `https://remote-falcon-images.nyc3.cdn.digitaloceanspaces.com` portion as this is an incorrect link.

Substite `https://your_domain.com/remote-falcon-images` instead and you will get a usable link when you add the image path `/yourshowname/yourimagename.png`.

!!! example "Example image path for an image hosted from MinIO"

    `https://your_domain.com/remote-falcon-images/yourshowname/sl3gtwl.png`

## Swap Viewer Page Subdomain

The Control Panel is normally accessible at `https://your_domain.com` but can be swapped with a Viewer Page when `SWAP_CP` is set to true and `VIEWER_PAGE_SUBDOMAIN` is set to a valid Viewer Page Subdomain in the [.env](../architecture/files.md#env) file.

This makes your Viewer Page accessible at `https://your_domain.com` and the Control Panel accessible at `https://controlpanel.your_domain.com`. 

The [configure-rf](../scripts/index.md#__tabbed_1_1) script offers to modify these variables under the OPTIONAL variables section.

```sh title="Enable SWAP_CP and set VIEWER_PAGE_SUBDOMAIN"
❓ Update OPTIONAL variables? (y/n) [n]: y
...
...
🔁 Would you like to swap the Control Panel and Viewer Page URLs? (y/n) [n]: y
🌐 Enter your Viewer Page Subdomain []: enteryourshownamehere
```

To undo these changes, re-run the configure-rf script and answer `y` at the REVERT question.

This will make the Control Panel accessible at `https://your_domain.com`.

```sh title="Disable SWAP_CP"
❓ Update OPTIONAL variables? (y/n) [n]: y
...
...
🔁 Would you like to REVERT the Control Panel and Viewer Page URLs back to the default? (y/n) [n]: y
```