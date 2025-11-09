The [configure-rf](../about/scripts.md#configure-rfsh) script will help configure the [.env](../about//files.md#env) variables that are required to run Remote Falcon. It will also kick off other helper scripts to update container tags and perform some health checks after all containers are up and running.

## Download and run configure-rf script interactively

1. Download the script to your desired directory. Your current directory can be verified with `#!sh pwd` command.

2. Run the command below. The command will download the [configure-rf](../about/scripts.md#configure-rfsh) script, make it executable, and run it automatically.
   
      ```sh
      curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh; \
      chmod +x configure-rf.sh; \
      ./configure-rf.sh
      ```

!!! note

      The configure-rf script will automatically download additional helper scripts and create 'remotefalcon' and 'remotefalcon-backups' directories.

If you did not create a Cloudflare API token for [automatic configuration](cloudflare.md#automatic-configuration) of Cloudflare then make sure you have the following information available to copy and paste as the configuration script will ask for these:

- [Cloudflare Tunnel](https://one.dash.cloudflare.com/) token

- [Cloudflare](https://dash.cloudflare.com/) origin server certificate

- [Cloudflare](https://dash.cloudflare.com/) origin server private key

If you want to use GitHub to build Remote Falcon images:

- [GitHub Personal Access Token](https://github.com/settings/tokens)

If everything went to plan with the configuration the [health_check](../about/scripts.md#health_checksh) script should show everything OK and will present you with a link to access Remote Falcon.

If all looks OK you can then move on to [post install](../post-install.md) or if you see errors check the [troubleshooting](../troubleshooting.md) section.

The configuration script can be re-run with `#!sh ./configure-rf.sh` to help make any changes if needed.

You can also directly run the [health_check](../about/scripts.md#health_checksh) or [update_containers](../about/scripts.md#update_containerssh)  helper scripts directly as well.

## Non-interactive/automatic installation

The configure-rf script can be run non-interactively to speed up installation if you already know what values you would like to set.

Below are just a few examples.

Replace the generic values with your own.

```sh title="Download and install with automatic Cloudflare configuration and remote image building on GitHub"
sudo apt-get update && sudo apt-get install curl -y; \
curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh; \
chmod +x configure-rf.sh; \
./configure-rf.sh -y \
--set DOMAIN=YOURDOMAIN.COM \
--set CF_API_TOKEN=REPLACE_WITH_YOUR_CF_API_TOKEN \
--set GITHUB_PAT=REPLACE_WITH_YOUR_GITHUB_PAT
```

```sh title="Download and install with automatic Cloudflare configuration and local image building"
sudo apt-get update && sudo apt-get install curl -y; \
curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh; \
chmod +x configure-rf.sh; \
./configure-rf.sh -y \
--set DOMAIN=YOURDOMAIN.COM \
--set CF_API_TOKEN=REPLACE_WITH_YOUR_CF_API_TOKEN
```

After initial setup you can re-run the configure-rf script to make additional changes.

```sh title="Swap your viewer page with the Control Panel and disable auto validate email"
./configure-rf.sh -y --no-updates \
--set AUTO_VALIDATE_EMAIL=false \
--set SWAP_CP=true \
--set VIEWER_PAGE_SUBDOMAIN=yourviewerpage
```