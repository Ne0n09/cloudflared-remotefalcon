# cloudflared-remotefalcon
Self hosted Remote Falcon with easy setup and configuration using Cloudflare Tunnels.

[Remote Falcon](https://remotefalcon.com/) is an awesome project and I thought I would help give back by creating an alternate way to run Remote Falcon for those who would like to self host it beyond just these [ways](https://docs.remotefalcon.com/docs/developer-docs/running-it/methods)

We will start with the Cloudflare configuration.

This guide assumes you already have a domain name and that you are running a fresh installation of Debian or Ubuntu.

The RF configuration script will check if you have Docker installed and install it for you if not. 

It will also guide you step by step to creating and saving the origin server certificates. 

I have modified the compose file to allow for everything to be run from Docker, requiring only Docker be installed on the host. 

There is no need to open up port 443 when going through the Cloudflare tunnel.

There is no need to manually edit the compose.yaml or default.conf file.

The .env file handles the configuration variables and the configure-rf.sh script walks you through setting these variables and applying them.

__NOTE__ This guide is a working progress

## Cloudflare Configuration
This configuration will go over the Cloudflare DNS, certificate, and tunnel configuration.

### Certificates
We'll start with the certificates.

This is what I have configured and it works for my setup.

Enable the options under each section.

SSL/TLS -> Edge Certificates

1. Always Use HTTPS
2. Opportunistic Encryption
3. TLS 1.3

SSL/TLS -> Client Certificates
I have a created certificate here, but I don't think I'm using it at the moment.

SSL/TLS -> Origin Server

Create an origin certificate and copy down the certificate and private key. 

These will be used later in the Remote Falcon configuration script.

The free Cloudflare plan does not let you create wildcard certificates for sub-sub-domains(ex: *sub.sub.yourdomain.com)

Create the certificate such as:

*.yourdomain.com, yourdomain.com

### Cloudflare Tunnel

Go back to the main Cloudflare dashboard page if not there already.

1. Click Zero Trust
2. Click Networks
3. Create a tunnel
4. Select Cloudflared and click Next
5. Pick any name you would like for your tunnel.
6. Save tunnel
7. Select Docker under choose your environment
8. Copy the whole 'docker run cloudflare' command and paste it into a notepad.
9. Ensure you have the whole token. We will need it later in the configuration script.
10. Click Next

First public hostname

Subdomain: blank

Domain: your.domain.com

Service Type: HTTPS:

Service URL: nginx

Additional application settings -> TLS

1. Origin Server name: *.yourdomain.com
2. HTTP2 connection: On

Click Save tunnel

__NOTE:___ You may receive an error if you already have DNS records. You will need to delete any existing A records or CNAME records pointing to * or yourdomain.com

Second public hostname

Click the newly created tunnel and click Edit.

Select Public Hostname

Click + Add a public hostname

Subdomain: *

___NOTE:___ Ignore the warning about 'This domain contains a wildcard." We will manually add the wildcard entry under the DNS settings later.

Domain: yourdomain.com

Service Type: HTTPS

Service URL: nginx

1. Origin Server name: *.yourdomain.com
2. HTTP2 connection: On

Click Save hostname

Catch-all rule: https://nginx

### DNS

With the Cloudflare tunnel configuration completed. Go back to the main Cloudflare dashboard.

Select DNS -> Records

You should see a CNAME record that was created automatically for the tunnel, (ex: 248a0b11-e62a-4b0e-8e30-123456789101112.cfargotunnel.com)

Click Edit on the yourdomain.com CNAME record and copy the Target(ending with cfargotunnel.com)

Click Cancel

Click + Add Record

Type: CNAME

Name: *

Target: Paste your complete cfargotunnel.com Target

Click Save

Now you should have two DNS records pointing to your .cfargotunnel target.

CNAME * 248a0b11-e62a-4b0e-8e30-123456789101112.cfargotunnel.com

CNAME yourdomain.com 248a0b11-e62a-4b0e-8e30-123456789101112.cfargotunnel.com

Both should be proxied.

Scroll down and you should see the Cloudflare Nameservers.

Ensure that you are using these name servers with your domain name registrar/provider.

## Remote Falcon Installation
Download the configuration script, make it executable and run it!

1. Download the script.
   
   ```curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh```
3. Make it executable.
   
   ```chmod +x configure-rf.sh```
5. Run it.
   
   ```./configure-rf.sh```

Be sure to have your origin server certificate, origin private key, and tunnel token available in a notepad. The configuration script will ask for these.

## Notes

___This Guide is a work in progress___

This guide assumes you are not running nginx on the host. 

If nginx is running on the host you will need to stop it from running.

  ```sudo systemctl stop nginx```

You can also uninstlal nginx, note thah this would remove all files under /etc/nginx!

  ```sudo apt purge nginx nginx-common nginx-core```
  
  ```sudo apt autoremove```

Everything should work as you would expect from Remote falcon. The only thing that I could not get to work is the viewer counts. RF will not log the last IP used to log into RF as a viewer, but even with testing from devices that have never logged into the RF dashboard I could not get the viewer count to increment for my show page.

## Troubleshooting

___Unexpected Error___
Ensure your web browser is pointing you to https://yourdomain.com and *NOT* https://www.yourdomain.com

There may also may be other causes for this error that I am not aware of.

Below you will find some useful troubleshooting commands.

Test the nginx configuration file: 

```sudo docker exec nginx nginx -t = test conf file```

Show the nginx configuration file that is being used:

```sudo docker exec nginx nginx -T = show conf file```

Display logs from the nginx container (Or any other container by changing the 'nginx' name at the end):

```sudo docker logs nginx```

Display the status of the Cloudflare tunnel in the Cloudflared container:

  ```sudo docker exec cloudflared cloudflared tunnel list```

Access mongo container CLI and mongo shell to run mongo shell commands:

```sudo docker exec -it mongo bash```
 
  ```mongosh "mongodb://root:root@localhost:27017"```
 
  ```use remote-falcon```
	
To find shows: 

  ```db.show.find()```

To delete shows:

  ```db.show.deleteOne( { showName: 'Test3' } )```
