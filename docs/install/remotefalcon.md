The [configure-rf](../about/scripts.md#configure-rfsh) script will help configure the [.env](../about//files.md#env) variables that are required to run Remote Falcon. It will also kick off other helper scripts to update container tags and perform some health checks after all containers are up and running.

## Download and run configure-rf script

1. Download the script to your desired directory. Your current directory can be verified with `#!sh pwd` command.

2. Run the command below. The command will download the [configure-rf](../about/scripts.md#configure-rfsh) script, make it executable, and run it automatically.
   
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

If everything went to plan with the configuration the [health_check](../about/scripts.md#health_checksh) script should show everything OK and will present you with a link to access Remote Falcon.

If all looks OK you can then move on to [post install](../post-install.md) or if you see errors check the [troubleshooting](../troubleshooting.md) section.

The configuration script can be re-run with `#!sh ./configure-rf.sh` to help make any changes if needed.

You can also directly run the [health_check](../about/scripts.md#health_checksh) or [update_containers](../about/scripts.md#update_containerssh)  helper scripts directly as well.