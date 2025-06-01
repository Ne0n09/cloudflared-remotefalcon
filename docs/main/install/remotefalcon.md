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

If everything went to plan with the configuration you should see your containers all up similar to below:

```
CONTAINER ID   IMAGE                                      COMMAND                  CREATED          STATUS          PORTS                                                             NAMES
9a6a8428cace   control-panel:e6c110c                      "/bin/sh -c 'exec ja…"   21 seconds ago   Up 20 seconds   8080/tcp                                                          control-panel
9279b7669e75   minio/minio:RELEASE.2025-05-24T17-08-30Z   "/usr/bin/docker-ent…"   38 seconds ago   Up 37 seconds   0.0.0.0:9000-9001->9000-9001/tcp, [::]:9000-9001->9000-9001/tcp   remote-falcon-images.minio
5549dad80125   ui:cb19864                                 "docker-entrypoint.s…"   49 seconds ago   Up 47 seconds   3000/tcp                                                          ui
73cfd4d5f7da   external-api:f7e09fe                       "/bin/sh -c 'exec ja…"   50 seconds ago   Up 48 seconds   8080/tcp                                                          external-api
f68aacb72ec3   viewer:b7cfb2d                             "/app/application -D…"   50 seconds ago   Up 48 seconds   8080/tcp                                                          viewer
d1b5f2540758   plugins-api:cc1593a                        "/bin/sh -c 'exec ja…"   50 seconds ago   Up 48 seconds   8080/tcp, 0.0.0.0:8083->8083/tcp, [::]:8083->8083/tcp             plugins-api
dd12ab4fa10c   mongo:8.0.9                                "docker-entrypoint.s…"   51 seconds ago   Up 48 seconds   27017/tcp                                                         mongo
aa85a908e37a   nginx:latest                               "/docker-entrypoint.…"   51 seconds ago   Up 47 seconds   80/tcp                                                            nginx
db51c56fbbfd   cloudflare/cloudflared:latest              "cloudflared --no-au…"   51 seconds ago   Up 48 seconds                                                                     cloudflared
```

If all looks OK you can then move on to [post install](../post-install.md) or if you see errors check the [troubleshooting](../../troubleshooting/index.md) section.

The configuration script can be re-run with `#!sh ./configure-rf.sh` to help make any changes if needed.

You can also directly run the [health_check](../../scripts/index.md#__tabbed_1_4), [update_rf_containers](../../scripts/index.md#__tabbed_1_2), or [update_containers](../../scripts/index.md#__tabbed_1_3) helper scripts directly as well.

!!! example "Example syntax for helper scripts"

      ```
      ./health_check.sh
      ./update_rf_containers.sh
      ./update_rf_containers.sh dry-run
      ./update_rf_containers.sh auto-apply
      ./update_containers.sh
      ./update_containers.sh cloudflared auto-apply health
      ./update_containers.sh nginx dry-run
      ./update_containers.sh mongo
      ```