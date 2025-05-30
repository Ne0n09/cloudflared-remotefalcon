**WORK IN PROGRESS**

### Unexpected Error

- **Control Panel**: Ensure your web browser is pointing you to `https://yourdomain.com` and *NOT `www`:* `https://www.yourdomain.com`

- **Viewer page**: Make sure you're browsing to your show page sub-domain. You can find this by clicking the gear icon on the top right of the Remote Falcon control panel. It will show `https://yourshowname.remotefalcon.com` So for your show on your self hosted RF you would go to `https://yourshowname.yourdomain.com`

### err_quic_protocol_error in browser

Try to restart the cloudflared container:

```sh
sudo docker restart cloudflared
```

Otherwise, it could be something going on with Cloudflare.

### Control Panel Dashboard Viewer Statistics

The Control Panel Dashboard will not count the last IP that was used to login to the Control Panel in the viewer statistics when viewing your show page. 

If you want to test if viewer statistics are working you can disconnect your phone from Wi-Fi and then check from a desktop/laptop that's logged into the Control Panel.

### Mongo Container Restarting

If your Mongo container is constantly restarting when checking `#!sh sudo docker ps` then check the logs with `#!sh sudo docker logs mongo`

If you see a message similar to the below you will need to downgrade the Mongo image to a version prior to 5.0 if your CPU does not support AVX.

```
WARNING: MongoDB 5.0+ requires a CPU with AVX support, and your current system does not appear to have that!
see https://jira.mongodb.org/browse/SERVER-54407
see also https://www.mongodb.com/community/forums/t/mongodb-5-0-cpu-intel-g4650-compatibility/116610/2
see also https://github.com/docker-library/mongo/issues/485#issuecomment-891991814
```
If you are running a VM in a system such as Proxmox you can try changing the CPU type to '`host`'. 

To downgrade you can check the latest version of 4 here [Mongo 4.x tags](https://hub.docker.com/_/mongo/tags?page_size=&ordering=&name=4.)

Update the image tag in your compose.yaml

```sh
nano remotefalcon/compose.yaml
```

Modify the Mongo image line:

```yaml title="compose.yaml" linenums="27" hl_lines="2"
  mongo:
    image: mongo:latest
```

To add the specific 4.x version tag that you would like to use from [Mongo 4.x tags](https://hub.docker.com/_/mongo/tags?page_size=&ordering=&name=4.)

```yaml title="compose.yaml" linenums="27" hl_lines="2"
  mongo:
    image: mongo:4.0.28
```

### Show page is always redirected to the Control Panel

When attempting to browse to `https://yourshowname.yourdomain.com` it always redirects to the Remote Falcon Control Panel. 

This is caused by *`HOSTNAME_PARTS`* being set to 3 when everything else(Tunnel public hostnames/DNS) is configured for 2 parts.  

To correct this issue, ensure you set *`HOSTNAME_PARTS`* to 2 in the .env file and make sure to update your origin certificates using the configuration script so the certificate file names are propoerly updated for the 2-part domain. 

### Viewer page Now playing/Up next not updating as expected

You will observe intermittent and random times where the Now playing/Up next do not update and requests also do not play. 

After waiting 15 minutes or so things will start working as expected again.

You can check the FPP logs by going to Content Setup -> File Manager -> Logs

Check *remote-falcon-listener.log* and look for any gaps in the logs where you would expect sequences to be updated.

Example, note the gap where there are not updates from 7:11:45 PM to 7:29:53 PM:

```
2024-10-26 07:11:45 PM: /home/fpp/media/plugins/remote-falcon/remote_falcon_listener.php : [] Updated current playing sequence to Michael Jackson - Thriller
2024-10-26 07:11:45 PM: /home/fpp/media/plugins/remote-falcon/remote_falcon_listener.php : [] Updated next scheduled sequence to The Hit Crew -The Addams Family
2024-10-26 07:29:53 PM: /home/fpp/media/plugins/remote-falcon/remote_falcon_listener.php : [] Updated current playing sequence to Fall Out Boy - My Songs Know What You Did In The Dark (Light Em Up)
2024-10-26 07:29:54 PM: /home/fpp/media/plugins/remote-falcon/remote_falcon_listener.php : [] Updated next scheduled sequence to Geoff Castellucci - Monster Mash
```

Check */var/log/syslog* for around the same time frame of any gaps noticed in the *remote-falcon-listener.log*.

If you see errors such as the below at the end of the gap timeframe(7:29 PM) then there is some type of connectivity issue between the plugins-api and FPP.

```
Oct 26 19:29:52 FPP fppd_boot_post[2128]: PHP Warning:  file_get_contents(): SSL: Handshake timed out in /home/fpp/media/plugins/remote-falcon/remote_falcon_listener.php on line 376
Oct 26 19:29:52 FPP fppd_boot_post[2128]: PHP Warning:  file_get_contents(): Failed to enable crypto in /home/fpp/media/plugins/remote-falcon/remote_falcon_listener.php on line 376
Oct 26 19:29:52 FPP fppd_boot_post[2128]: PHP Warning:  file_get_contents(https://yourdomain.com/remote-falcon-plugins-api/nextPlaylistInQueue?updateQueue=true): failed to open stream: operation failed in /home/fpp/media/plugins/remote-falcon/remote_falcon_listener.php on line 376
```

To resolve, we can publish the plugins-api port and configure the FPP plugin to connect locally to plugins-api to avoid FPP from having to go out to the internet to reach the plugins-api:

1. Modify the `compose.yaml` and update the plugins-api container to publish port 8083(if it is not already published):

    ```yaml title="compose.yaml" linenums="50" hl_lines="9-10"
      plugins-api:
        build:
          context: https://github.com/Remote-Falcon/remote-falcon-plugins-api.git
          args:
            - OTEL_OPTS=
        image: plugins-api
        container_name: plugins-api
        restart: always
        ports:
          - "8083:8083"
    ```

2. Restart the containers with `#!sh sudo docker compose down` and `#!sh sudo docker compose up -d`

3. `#!sh sudo docker ps` will show the plugins-api is now published on port 8083: 
```
ONTAINER ID   IMAGE                              COMMAND                  CREATED       STATUS       PORTS                                                 NAMES
c3dc4de3a19b   plugins-api:fe7c932                "/bin/sh -c 'exec ja…"   5 hours ago   Up 5 hours   8080/tcp, 0.0.0.0:8083->8083/tcp, :::8083->8083/tcp   plugins-api
```

4. In the FPP plugin settings update the Plugins API path to the IP address of your local self hosted RF instance: `http://ip.address.of.remote.falcon:8083/remote-falcon-plugins-api`

5. Reboot FPP.

## Troubleshooting Commands

### NGINX

Test the NGINX configuration file: 

```sh
sudo docker exec nginx nginx -t
```

Show the NGINX configuration file that is being used:

```sh
sudo docker exec nginx nginx -T
```

Display logs from the NGINX container (Or any other container by changing the 'nginx' name at the end):

```sh
sudo docker logs nginx
```

### Cloudflared

Display the status of the Cloudflare tunnel in the Cloudflared container. You will have to open the login link and login to Cloudflare before running the list command.

  ```sh
  sudo docker exec cloudflared cloudflared tunnel login
  sudo docker exec cloudflared cloudflared tunnel list
  ```

### Mongo

Access mongo container CLI and mongo shell to run mongo shell commands:

```sh
sudo docker exec -it mongo bash
mongosh "mongodb://root:root@localhost:27017" 
use remote-falcon
```
	
To find shows: 

  ```sh
  db.show.find()
  ```

To delete shows:

  ```sh
  db.show.deleteOne( { showName: 'Test3' } )
  ```