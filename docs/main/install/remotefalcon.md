The [configure-rf](../../scripts/index.md#__tabbed_1_1) script will help configure the [.env](../../architecture/files.md#env) variables that are required to run Remote Falcon. It will also kick off other helper scripts to update container tags and perform some health checks after all containers are up and running.

## Download and run configure-rf script

1. Download the script to your desired directory. Your current directory can be verified with `#!sh pwd` command.

2. Run the command below. The command will download the [configure-rf](../../scripts/index.md#__tabbed_1_1) script, make it executable, and run it automatically.
   
      ```sh
      curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh; \
      chmod +x configure-rf.sh; \
      ./configure-rf.sh
      ```

!!! note

      The configure-rf script will automatically download additional helper scripts and create 'remotefalcon' and 'remotefalcon-backups' directories.

Make sure you have the following information available to copy and paste as the configuration script will ask for these:

- [Cloudflare Tunnel](https://one.dash.cloudflare.com/) token

- [Cloudflare](https://dash.cloudflare.com/) origin server certificate

- [Cloudflare](https://dash.cloudflare.com/) origin server private key

- [GitHub Personal Access Token](https://github.com/settings/tokens) if you want to use GitHub to build Remote Falcon images

If everything went to plan with the configuration the [health_check](../../scripts/index.md#__tabbed_1_3) script should show everything OK and will present you with a link to access Remote Falcon.

If all looks OK you can then move on to [post install](../post-install.md) or if you see errors check the [troubleshooting](../../troubleshooting/index.md) section.

The configuration script can be re-run with `#!sh ./configure-rf.sh` to help make any changes if needed.

You can also directly run the [health_check](../../scripts/index.md#__tabbed_1_3) or [update_containers](../../scripts/index.md#__tabbed_1_2)  helper scripts directly as well.