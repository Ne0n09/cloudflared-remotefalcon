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