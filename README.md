# cloudflared-remotefalcon

Self hosted Remote Falcon with easy setup and configuration using Cloudflare Tunnels with a configuration script.

[Remote Falcon](https://remotefalcon.com/) is an awesome project and I thought I would help give back by creating a simplified way to run Remote Falcon for those who would like to self host it beyond just these [ways](https://docs.remotefalcon.com/docs/developer-docs/running-it/methods)

This guide assumes you already have a domain name and that you are running a fresh installation of Debian or Ubuntu.

The configuration script will check if you have Docker installed and install it for you if not. 

It will also guide you step by step to creating and saving the origin server certificates. 

Everything will run as a 'compartmentalized' stack that is only accessible via the Cloudflare tunnel pointing to an NGINX container handles the proxying to the Remote Falcon containers. This also avoids port conflicts on your host system.

The main benefit of this method is there is no need to directly expose port 443 when going through the Cloudflare tunnel.

The .env file handles the configuration variables and the configure-rf.sh script walks you through setting these variables and applying them.

There is no need to manually edit the compose.yaml or the NGINX default.conf file.

We will start with the Cloudflare configuration below.

## Cloudflare Configuration

This configuration will go over the Cloudflare DNS, certificate, and tunnel configuration.

[!NOTE]
The tunnel configuration requires a Cloudflare Zero Trust account, which is free, but will require you to enter a payment method(Credit card or PayPal).

### Add Domain Name to Cloudflare

If not already added, you'll have to add your domain name to Cloudflare

Go to the [Cloudflare Dashboard](https://dash.cloudflare.com/) and click Add a Domain.

Enter your existing domain name or purchase a new one from Cloudflare.

Click Continue

Select the Free plan and click Continue

Delete and existing A or CNAME records that are pointing to * or yourdomain.com and click Continue

Copy the Cloudflare nameservers and go to your domain name registrar and update the nameservers for your domain to the Cloudflare nameservers.

Click Continue on Cloudflare

Skip the Quick Start Guide by clicking Finish Later

You will have to wait some time for the new nameservers to take effect. 

Cloudflare will send you an email when your domain is available. You can continue with the additional setup so it will be ready to go when your domain is available.

### Certificates

Next we'll move on to the certificate configuration.

Click SSL/TLS on the left side of the Cloudflare Dashboard.

Enable the options under each section.

SSL/TLS -> Overview

1. Full(Strict)
2. Enable SSL/TLS Recommender 

SSL/TLS -> Edge Certificates

1. Enable Always Use HTTPS
2. Enable Opportunistic Encryption
3. Minimum TLS Version Select TLS 1.3
4. Enable TLS 1.3
5. Enable Automatic HTTPS Rewrites

> [!NOTE] 
> The free Cloudflare plan does not let you create wildcard certificates for sub-sub-domains(ex: *.sub.yourdomain.com) unless you purchase Advanced Certificate Manager.


SSL/TLS -> Client Certificates

The client certificate is not required for this configuration.

SSL/TLS -> Origin Server

Create an origin certificate and copy down the certificate and private key. 

These will be used later in the Remote Falcon configuration script.

Create the certificate such as:

*.yourdomain.com, yourdomain.com

### Cloudflare Tunnel

Go back to the main [Cloudflare Dashboard](https://dash.cloudflare.com/) page if not there already.

1. Click Zero Trust
2. Click Networks
3. Create a tunnel
4. Select Cloudflared and click Next
5. Pick any name you would like for your tunnel. Example: rf-yourdomain
6. Save tunnel
7. Select Docker under choose your environment
8. Copy the whole 'docker run cloudflare' command and paste it into a notepad.
9. Ensure you have the whole token. We will need it later in the configuration script.
10. Click Next

**First public hostname**

- Subdomain: blank

- Domain: yourdomain.com

- Service Type: HTTPS:

- Service URL: nginx

[!TIP]
The Service URL must be set to the NGINX container_name in the compose.yaml which is 'nginx' by default.

Click Additional application settings -> TLS

1. Origin Server name: *.yourdomain.com
2. HTTP2 connection: On

Click Save tunnel

[!WARNING] 
You may receive an error if you already have DNS records. You will need to delete any existing A or CNAME records pointing to * or yourdomain.com

![tunnel_public_hostname_page_settings](https://github.com/user-attachments/assets/721ad2fb-32b0-4262-9300-cef0a968ad66)

**Second public hostname**

Click the newly created tunnel and click Edit.

Click Public Hostname

Click + Add a public hostname

- Subdomain: *

- Domain: yourdomain.com

[!NOTE]
Ignore the warning about 'This domain contains a wildcard." We will manually add the wildcard entry under the DNS settings later.

- Service Type: HTTPS

- Service URL: nginx

Click *Additional application settings* -> TLS

1. Origin Server name: *.yourdomain.com
2. HTTP2 connection: On

Click *Save hostname*

![tunnel_public_hostname_page_settings_wildcard](https://github.com/user-attachments/assets/d7df0716-69bd-40df-8b60-8274e09059e2)

**Catch-all rule**

Click *Edit* to the right of the catch-all rule.

![tunnel_public_hostname_config](https://github.com/user-attachments/assets/e12c7b95-6fb5-40fd-a463-eb086f590cf9)

Type or paste ```https://nginx``` and click *Save*.

### DNS

With the Cloudflare tunnel configuration completed. Go back to the main [Cloudflare Dashboard](https://dash.cloudflare.com/).

Click yourdomain.com

Select DNS -> Records

You should see a CNAME record that was created automatically for the tunnel, (ex: CNAME yourdomain.com  248a0b11-e62a-4b0e-8e30-123456789101112.cfargotunnel.com)

Click + Add Record

Type: CNAME

Name: *

Target: yourdomain.com

Click Save

Now you should have two DNS records. Example:

- CNAME * yourdomain.com

- CNAME yourdomain.com 248a0b11-e62a-4b0e-8e30-123456789101112.cfargotunnel.com

Both should be proxied.

![DNS_Records_Argo_tunnel_config](https://github.com/user-attachments/assets/b67d1f28-708e-424c-8dd6-b50b7d006d68)

Scroll down and you should see the Cloudflare Nameservers.

Ensure that you are using these name servers with your domain name registrar/provider.

## Remote Falcon Installation

Make a directory for Remote Falcon, download the configuration script, make it executable and run it!

1. Make a directory to host the Remote Falcon files in your current directory. Your current directory can be verified with ```pwd```

   ```mkdir remotefalcon && cd remotefalcon```

1. Download the script.
   
   ```curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh```

3. Make it executable.
   
   ```chmod +x configure-rf.sh```
   
5. Run it.
   
   ```./configure-rf.sh```

Be sure to have your origin server certificate, origin private key, and tunnel token available in a notepad. The configuration script will ask for these.

If everything went to plan with the configuration you should see your containers all up similar to below:

```
CONTAINER ID   IMAGE                    COMMAND                  CREATED         STATUS         PORTS       NAMES
6a28663e81af   ui                       "docker-entrypoint.s…"   3 minutes ago   Up 3 minutes   3000/tcp    ui
47271a3f29df   viewer                   "/bin/sh -c 'exec ja…"   3 minutes ago   Up 3 minutes   8080/tcp    viewer
9b56286a455b   plugins-api              "/bin/sh -c 'exec ja…"   3 minutes ago   Up 3 minutes   8080/tcp    plugins-api
a925e26c4809   control-panel            "/bin/sh -c 'exec ja…"   3 minutes ago   Up 3 minutes   8080/tcp    control-panel
c590693f6165   mongo                    "docker-entrypoint.s…"   3 minutes ago   Up 3 minutes   27017/tcp   mongo
32cd8dfc3e5b   nginx                    "/docker-entrypoint.…"   3 minutes ago   Up 3 minutes   80/tcp      nginx
e6d4f3a547d8   cloudflare/cloudflared   "cloudflared --no-au…"   3 minutes ago   Up 3 minutes               cloudflared
```
You can re-run the configuration script to help make any changes as needed.

## Troubleshooting

### Unexpected Error

- Control Panel: Ensure your web browser is pointing you to https://yourdomain.com and *NOT www.* https://www.yourdomain.com 

- Viewer page: Make sure you're browsing to your show page sub-domain. You can find this by clicking the gear icon on the top right of the Remote Falcon control panel. It will show https://yourshowname.remotefalcon.com So for your show on your self hosted RF you would go to https://yourshowname.yourdomain.com

### err_quic_protocol_error in browser

Try to restart the cloudflared container:

```sudo docker restart cloudflared```

Otherwise, it could be something going on with Cloudflare.

### Control Panel Dashboard Viewer Statistics

The Control Panel Dashboard will not count the last IP that was used to login to the Control Panel in the viewer statistics when viewing your show page. 

If you want to test if viewer statistics are working you can disconnect your phone from Wi-Fi and then check from a desktop/laptop that's logged into the Control Panel.

### Mongo Container Restarting

If your Mongo container is constantly restarting when checking ```sudo docker ps``` then check the logs with ```sudo docker logs mongo```

If you see a message similar to the below you will need to downgrade the Mongo image to a version prior to 5.0 if your CPU does not support AVX.

```
WARNING: MongoDB 5.0+ requires a CPU with AVX support, and your current system does not appear to have that!
see https://jira.mongodb.org/browse/SERVER-54407
see also https://www.mongodb.com/community/forums/t/mongodb-5-0-cpu-intel-g4650-compatibility/116610/2
see also https://github.com/docker-library/mongo/issues/485#issuecomment-891991814
```
If you are running a VM in a system such as Proxmox you can try changing the CPU type to 'host'. 

To downgrade you can check the latest version of 4 here [Mongo 4.x tags](https://hub.docker.com/_/mongo/tags?page_size=&ordering=&name=4.)

Update the image tag in your compose.yaml

```nano compose.yaml```

Modify the Mongo image line:

```
  mongo:
    image: mongo
```

To add the specific 4.x version tag that you would like to use from [Mongo 4.x tags](https://hub.docker.com/_/mongo/tags?page_size=&ordering=&name=4.)

```
  mongo:
    image: mongo:4.0.28
```

### Show page is always redirected to the Control Panel

When attempting to browse to https://yourshowname.yourdomain.com it always redirects to the Remote Falcon Control Panel. 

This is caused by *HOSTNAME_PARTS* being set to 3 when everything else(Tunnel public hostnames/DNS) is configured for 2 parts.  

To correct this issue, ensure you set *HOSTNAME_PARTS* to 2 and make sure to update your origin certificates using the configuration script so the certificate file names are propoerly updated for the 2-part domain. 

### Troubleshooting Commands

Test the NGINX configuration file: 

```sudo docker exec nginx nginx -t```

Show the NGINX configuration file that is being used:

```sudo docker exec nginx nginx -T```

Display logs from the NGINX container (Or any other container by changing the 'nginx' name at the end):

```sudo docker logs nginx```

Display the status of the Cloudflare tunnel in the Cloudflared container:

  ```sudo docker exec cloudflared cloudflared tunnel list```

Access mongo container CLI and mongo shell to run mongo shell commands:

```
sudo docker exec -it mongo bash
mongosh "mongodb://root:root@localhost:27017" 
use remote-falcon
```
	
To find shows: 

  ```db.show.find()```

To delete shows:

  ```db.show.deleteOne( { showName: 'Test3' } )```

### Updating and pulling new Remote Falcon images

When changes are made to Remote Falcon sometimes it is necessary to pull a new image. The configuration script will ask if you want to rebuild the images which will run the commands below for you.

To remove the current Remote Falcon images you will have to bring Remote Falcon down, remove the, and bring RF back up:

```
sudo docker compose down
sudo docker image remove ui
sudo docker image remove viewer
sudo docker image remove control-panel
sudo docker compose up -d
```

### Updating or viewing the .env file manually outside of the configuration script

The configuration script isn't required to view or make updates to the .env file. You can manually edit the file, but the compose stack will have to be brought down manually and the Remote Falcon images rebuilt for some settings to take effect.

To view the .env file while you're in the remotefalcon directory:

```cat .env```

To manually edit the .env file:

```nano .env```


