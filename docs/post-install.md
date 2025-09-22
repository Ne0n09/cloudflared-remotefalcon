## Initial sign up and login

!!! note

    Ensure auto validate email was set to true to allow sign up on your Remote Falcon instance without email validation.

1. Go to `yourdomain.com` and click the Sign Up button

2. Create your account and sign in.

3. Click the gear icon in the top right -> Click Account Settings -> Click Account

4. Click the :material-content-copy: button to copy your `Show Token`.

## FPP 9 and below - Update the FPP plugin settings

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

          `http://ip.address.of.remote.falcon:8083`

          |                    | Developer Settings                                                   |
          |--------------------|----------------------------------------------------------------------|
          | Plugins API Path   |   http://localip.address.of.remote.falcon:8083  |

5. You can now continue with configuring your viewer page and other settings. Reference the [Remote Falcon Docs](https://docs.remotefalcon.com/docs/docs/welcome) if needed.

## FPP 9 and above - Update the FPP plugin settings

FPP 9 has some extra steps due to the addition of [Apache CSP](https://github.com/FalconChristmas/fpp/blob/master/docs/ApacheContentSecurityPolicy.md).

You will have to manually add your site to the trusted list or the plugins page will not load with the custom *Plugins API Path*.

1. In FPP go to Help -> :fontawesome-solid-terminal: SSH Shell

2. Login. The default user and password is fpp/falcon.


=== "DOMAIN"

    Follow this if you want to use your domain name to connect to the plugin.
    
    Select the other tab above to use your LAN IP as the commands are a bit different.

    1. Set the `DOMAIN` and `TOKEN` variable directly on the FPP shell to `https://yourdomain.com` and `yourshowtoken`.

        1. Click the :material-content-copy: button to copy the command below to a notepad and replace the default values `https://yourdomain.com` and `yourshowtoken` with your values next to `DOMAIN=` and `TOKEN=`.
        2. Copy your updated command string from notepad.
        3. Right-click the FPP shell window and click *Paste from browser*.
        4. Paste the command and click OK.
        5. Press Enter to run the command. 
        The command will print your values to the shell so that you can verify they are set properly.

        ```sh title="Copy this to a notepad and replace the default values"
        DOMAIN=https://yourdomain.com;TOKEN=yourshowtoken;echo -e "DOMAIN=$DOMAIN\nTOKEN=$TOKEN"
        ```

        !!! example "Example output of setting variables"
            ```sh
            fpp@FPP:~ $ DOMAIN=https://yourdomain.com;TOKEN=yourshowtoken;echo -e "DOMAIN=$DOMAIN\nTOKEN=$TOKEN"
            DOMAIN=https://yourdomain.com                                                                                                                         
            TOKEN=yourshowtoken
            ```

    2. Click the :material-content-copy: button below, paste in the FPP shell, and run the commands to add your site to the trusted list and update the plugin settings:

        ```sh title="Copy and paste this into the FPP shell to update everything"
        echo;echo "Adding '$DOMAIN' to Apache CSP...";sudo /opt/fpp/scripts/ManageApacheContentPolicy.sh add connect-src $DOMAIN;echo "Displaying currently configured domains for Apache CSP:";/opt/fpp/scripts/ManageApacheContentPolicy.sh show;echo "Updating Plugins API Path with '$DOMAIN'...";sed -i 's|^pluginsApiPath = ".*"|pluginsApiPath = '$DOMAIN/remote-falcon-plugins-api'|' media/config/plugin.remote-falcon;echo "Updating show token with '$TOKEN'...";sed -i "/^remoteToken =/c\remoteToken = ${TOKEN}" media/config/plugin.remote-falcon || echo "remoteToken = ${TOKEN}" >> media/config/plugin.remote-falcon;sed -i -e '/^init =/c\init = "true"' -e '$!b' -e '$a\init = "true"' media/config/plugin.remote-falcon;echo "Printing Remote Falcon Plugin configuration:";cat media/config/plugin.remote-falcon
        ```
        
        !!! example "Example output for yourdomain.com"
            ```sh hl_lines="13 22 26"
            Adding 'https://yourdomain.com' to Apache CSP...
            Domain 'https://yourdomain.com' added under 'connect-src'.
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
                "https://yourdomain.com"
            ],
            "object-src": []
            }
            Updating Plugins API Path with 'https://yourdomain.com'...
            Printing Remote Falcon Plugin configuration:
            pluginVersion = "2025.08.18.1"
            remotePlaylist = ""
            interruptSchedule = "false"
            remoteToken = "yourshowtoken"
            requestFetchTime = "3"
            additionalWaitTime = "0"
            fppStatusCheckTime = "1"
            pluginsApiPath = "https://yourdomain.com/remote-falcon-plugins-api"
            verboseLogging = "false"
            remoteFalconListenerEnabled = "true"
            remoteFalconListenerRestarting = "false"
            init = "true"
            ```

    3. Now you should be able to update the plugin settings normally in FPP. If you still have issues try rebooting or power cycling your FPP device.

=== "LAN"

    Follow this if you want to use your LAN IP to connect to the plugin. 
    
    Select the other tab above to use your domain as the commands are a bit different.

    1. Set the `DOMAIN` and `TOKEN` variable directly on the FPP shell to `http://localip.address.of.remote.falcon:8083` and `yourshowtoken`.

        1. Click the :material-content-copy: button to copy the command below to a notepad and replace the default values `http://localip.address.of.remote.falcon:8083` and `yourshowtoken` with your values next to `DOMAIN=` and `TOKEN=`.
        2. Copy your updated command string from notepad.
        3. Right-click the FPP shell window and click *Paste from browser*.
        4. Paste the command and click OK.
        5. Press Enter to run the command. 
        The command will print your values to the shell so that you can verify they are set properly.

        ```sh title="Copy this to a notepad and replace the default values"
        DOMAIN=http://localip.address.of.remote.falcon:8083;TOKEN=yourshowtoken;echo -e "DOMAIN=$DOMAIN\nTOKEN=$TOKEN"
        ```

        !!! example "Example output of setting variables"
            ```sh
            fpp@FPP:~ $ DOMAIN=http://localip.address.of.remote.falcon:8083;TOKEN=yourshowtoken;echo -e "DOMAIN=$DOMAIN\nTOKEN=$TOKEN"
            DOMAIN=http://localip.address.of.remote.falcon:8083                                                                                                                       
            TOKEN=yourshowtoken
            ```

    2. Click the :material-content-copy: button below, paste in the FPP shell, and run the commands to add your site to the trusted list and update the plugin settings:

        ```sh title="Copy and paste this into the FPP shell to update everything"
        echo;echo "Adding '$DOMAIN' to Apache CSP...";sudo /opt/fpp/scripts/ManageApacheContentPolicy.sh add connect-src $DOMAIN;echo "Displaying currently configured domains for Apache CSP:";/opt/fpp/scripts/ManageApacheContentPolicy.sh show;echo "Updating Plugins API Path with '$DOMAIN'...";sed -i 's|^pluginsApiPath = ".*"|pluginsApiPath = '$DOMAIN'|' media/config/plugin.remote-falcon;echo "Updating show token with '$TOKEN'...";sed -i "/^remoteToken =/c\remoteToken = ${TOKEN}" media/config/plugin.remote-falcon || echo "remoteToken = ${TOKEN}" >> media/config/plugin.remote-falcon;sed -i -e '/^init =/c\init = "true"' -e '$!b' -e '$a\init = "true"' media/config/plugin.remote-falcon;echo "Printing Remote Falcon Plugin configuration:";cat media/config/plugin.remote-falcon
        ```
        
        !!! example "Example output for http://localip.address.of.remote.falcon:8083"
            ```sh hl_lines="13 22 26"
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
            pluginVersion = "2025.08.18.1"
            remotePlaylist = ""
            interruptSchedule = "false"
            remoteToken = "yourshowtoken"
            requestFetchTime = "3"
            additionalWaitTime = "0"
            fppStatusCheckTime = "1"
            pluginsApiPath = "http://localip.address.of.remote.falcon:8083"
            verboseLogging = "false"
            remoteFalconListenerEnabled = "true"
            remoteFalconListenerRestarting = "false"
            init = "true"
            ```

    3. Now you should be able to update the plugin settings normally in FPP. If you still have issues try rebooting or power cycling your FPP device.

## Swap Viewer Page Subomdain

Enable this if you would like visitors to be able to directly visit your show page at `https://yourdomain.com` instead of `https://yourshowname.yourdomain.com`.

!!! note

    You must first create an account before you can enable this along with creating a Viewer Page and setting it as active under Remote Falcon Settings.

1. Run `./configure-rf`
2. Enter `y` to change the variables
3. Press `Enter` to accept current values until you get to **Update OPTIONAL variables?** where you enter `y`
4. Press `Enter` to accept current values until you get to **Would you like to swap the Control Panel and Viewer Page Subdomain URLs?** where you enter `y`
5. Type in your Viewer Page Subdomain, example: `mylightshow` and press `Enter`
6. Enter `y` to accept the changes

!!!warning

    A rebuild of all Remote Falcon containers will be performed in order for these changes to take effect.

## Remote Falcon Image hosting

If [minio_init](about/scripts.md#minio_initsh) script ran successfully and configured MinIO then you are able to make use of the Image Hosting page in the Control Panel.

If it is not configured succesfully, you will be greeted with a blank white page after attempting to upload an image.

Otherwise, uploading images should display a `image-name.png uploaded successfully.` message and you will see it in the list of images such as below:

| Preview | Image URL                                                                                       | Actions |
|---------|--------------------------------------------------------------------------------------------------|---------|
| :material-image-broken: | `https://remote-falcon-images.nyc3.cdn.digitaloceanspaces.com/yourshowname/linkedin.png` | :octicons-trash-16:     |
| :material-image-broken: | `https://remote-falcon-images.nyc3.cdn.digitaloceanspaces.com/yourshowname/sl3gtwl.png`  | :octicons-trash-16:     |

!!!warning

    Ignore the `https://remote-falcon-images.nyc3.cdn.digitaloceanspaces.com` portion as this is an incorrect link.

Substitute `https://yourdomain.com/remote-falcon-images` instead and you will get a usable link when you add the image path `/yourshowname/yourimagename.png`.

!!! example "Example image path for an image hosted from MinIO"

    `https://yourdomain.com/remote-falcon-images/yourshowname/sl3gtwl.png`