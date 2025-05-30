**WORK IN PROGRESS* *

## Initial sign up and login

Ensure auto validate email was set to true to allow sign up on your Remote Falcon instance without email validation.

## Remote Falcon Image hosting

If [`#!sh minio-init.sh`](../scripts/index.md#__tabbed_1_7){ data-preview } ran successfully and configured MinIO then you are able to make use of the Image Hosting page in the Control Panel.

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