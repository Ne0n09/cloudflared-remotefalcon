## Remote Falcon Installation

Download the configuration script, make it executable and run it!

### Download configure-rf.sh

1. Download the script to your desired directory. The script will create a 'remotefalcon' directory if it does not already exist. Your current directory can be verified with ```pwd```
   
   ```curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh```

3. Make it executable.
   
   ```chmod +x configure-rf.sh```
   
5. Run it.
   
   ```./configure-rf.sh```

Be sure to have your origin server certificate, origin private key, and tunnel token available in a notepad. The configuration script will ask for these.

If everything went to plan with the configuration you should see your containers all up similar to below:

```
CONTAINER ID   IMAGE                              COMMAND                  CREATED          STATUS          PORTS                                                 NAMES
7dd138f36842   ui:e36968c                         "docker-entrypoint.s…"   21 seconds ago   Up 20 seconds   3000/tcp                                              ui
790cd1e80d86   plugins-api:fe7c932                "/bin/sh -c 'exec ja…"   22 seconds ago   Up 20 seconds   8080/tcp, 0.0.0.0:8083->8083/tcp, :::8083->8083/tcp   plugins-api
4cd6197ae142   control-panel:3557af5              "/bin/sh -c 'exec ja…"   22 seconds ago   Up 20 seconds   8080/tcp                                              control-panel
379bd760736d   viewer:07edd6a                     "/bin/sh -c 'exec ja…"   22 seconds ago   Up 20 seconds   8080/tcp                                              viewer
18e6c6d8e79c   external-api:a9f4918               "/bin/sh -c 'exec ja…"   22 seconds ago   Up 20 seconds   8080/tcp                                              external-api
04e92027115c   cloudflare/cloudflared:2024.12.1   "cloudflared --no-au…"   22 seconds ago   Up 21 seconds                                                         cloudflared
51e2d60ef8f9   mongo:latest                       "docker-entrypoint.s…"   22 seconds ago   Up 21 seconds   27017/tcp                                             mongo
6e052fb1fe39   nginx:latest                       "/docker-entrypoint.…"   22 seconds ago   Up 20 seconds   80/tcp                                                nginx
```

You can re-run the configuration script to help make any changes as needed.

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

In FPP go to Content Setup -> Remote Falcon

Enter your *show token* from your self-hosted Remote Falcon account settings.

Update the *Plugins API Path* to your domain: ```https://yourdomain.com/remote-falcon-plugins-api```

> [!TIP] 
> If you have local access to your FPP player you can directly connect to the plugins-api container if port 8083 is published: 
>
>  ```http://ip.address.of.remote.falcon:8083/remote-falcon-plugins-api```

Reboot FPP after applying the changes.