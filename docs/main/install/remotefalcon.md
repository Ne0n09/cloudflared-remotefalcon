## Remote Falcon Installation

Download the configuration script, make it executable and run it!

### Download configure-rf.sh

1. Download the script to your desired directory. The script will create a 'remotefalcon' directory if it does not already exist. Your current directory can be verified with ```pwd```
      
      ```sh
      curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh
      ```

2. Make it executable.
   
      ```sh
      chmod +x configure-rf.sh
      ```
   
3. Run it.
   
      ```sh
      ./configure-rf.sh
      ```

Make sure you have th following information available to copy and paste as the configuration script will ask for these:

- Cloudflare tunnel token

- Cloudflare origin server certificate

- cloudflare origin sever private key

If everything went to plan with the configuration you should see your containers all up similar to below:

```
CONTAINER ID   IMAGE                           COMMAND                  CREATED          STATUS          PORTS                                                             NAMES
f38d434383c7   ui:cb19864                      "docker-entrypoint.s…"   23 seconds ago   Up 20 seconds   3000/tcp                                                          ui
682fd072df2c   viewer:b7cfb2d                  "/app/application -D…"   23 seconds ago   Up 21 seconds   8080/tcp                                                          viewer
e78d5ecc4e49   plugins-api:cc1593a             "/bin/sh -c 'exec ja…"   23 seconds ago   Up 21 seconds   8080/tcp, 0.0.0.0:8083->8083/tcp, [::]:8083->8083/tcp             plugins-api
bb84cd53ca8b   external-api:f7e09fe            "/bin/sh -c 'exec ja…"   23 seconds ago   Up 21 seconds   8080/tcp                                                          external-api
25d49eabda54   control-panel:e6c110c           "/bin/sh -c 'exec ja…"   23 seconds ago   Up 21 seconds   8080/tcp                                                          control-panel
8e101b4b0479   cloudflare/cloudflared:latest   "cloudflared --no-au…"   23 seconds ago   Up 22 seconds                                                                     cloudflared
f84b69cd33a0   minio/minio:latest              "/usr/bin/docker-ent…"   23 seconds ago   Up 22 seconds   0.0.0.0:9000-9001->9000-9001/tcp, [::]:9000-9001->9000-9001/tcp   remote-falcon-images.minio
21d6471342dd   nginx:latest                    "/docker-entrypoint.…"   23 seconds ago   Up 21 seconds   80/tcp                                                            nginx
73dbed5b3b3d   mongo:latest                    "docker-entrypoint.s…"   23 seconds ago   Up 22 seconds   27017/tcp                                                         mongo
```

The configuration script can be re-run to help make any changes if needed.

You can also directly run the health_check, update_rf_containers, or update_containers scripts directly as well.

```
./health_check.sh
./update_rf_containers.sh --no-health
./update_containers.sh 
./update_containers.sh cloudflared
./update_containers.sh nginx
./update_containers.sh mongo
```

### Update the FPP plugin settings

1. In FPP go to Content Setup -> Remote Falcon

2. Enter your *show token* from your self-hosted Remote Falcon account settings.

3. Update the *Plugins API Path* to your domain: ```https://yourdomain.com/remote-falcon-plugins-api```

4. Reboot FPP after applying the changes.

!!! tip

      If you have local access to your FPP player you can directly connect to the plugins-api container if port 8083 is published: 

      ```http://ip.address.of.remote.falcon:8083/remote-falcon-plugins-api```
