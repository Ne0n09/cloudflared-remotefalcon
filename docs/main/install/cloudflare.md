## Cloudflare Configuration

This page covers the Cloudflare domain name, certificate, tunnel, and DNS configuration.

!!! note

    The tunnel configuration requires a Cloudflare Zero Trust account, which is free, but will require you to enter a payment method(Credit card or PayPal).

### Add Domain Name to Cloudflare

If not already added, you'll have to add your domain name to Cloudflare

1. Go to the [Cloudflare Dashboard](https://dash.cloudflare.com/) and click Add a Domain

2. Enter your existing domain name or purchase a new one from Cloudflare

3. Click Continue

4. Select the Free plan and click Continue

5. Delete any existing A or CNAME records that are pointing to * or yourdomain.com and click Continue

6. Copy the Cloudflare nameservers and go to your domain name registrar and update the nameservers for your domain to the Cloudflare nameservers.

7. Click Continue on Cloudflare

8. Skip the Quick Start Guide by clicking Finish Later

You will have to wait some time for the new nameservers to take effect. 

Cloudflare will send you an email when your domain is available. You can continue with the additional setup so it will be ready to go when your domain is available.

### Certificate

1. Click SSL/TLS on the left side of the Cloudflare Dashboard

2. Enable the options under each 'SSL/TLS' section

???+ info "SSL/TLS"

    === "Overview"

        1. Full(Strict)
        2. Enable SSL/TLS Recommender 

    === "Edge Certificates"

        1. Enable Always Use HTTPS
        2. Enable Opportunistic Encryption
        3. Minimum TLS Version Select TLS 1.3
        4. Enable TLS 1.3
        5. Enable Automatic HTTPS Rewrites

    === "Client Certificates"

        The client certificate is not required for this configuration

    === "Origin Server"

        Create an origin certificate and copy down the certificate and private key

        These will be used later in the Remote Falcon configuration script

        Create the certificate such as:

        !!! example "*.yourdomain.com, yourdomain.com"

    !!! warning
        The free Cloudflare plan does not let you create wildcard certificates for sub-sub-domains 
        (ex: *.sub.yourdomain.com) unless you purchase Advanced Certificate Manager.

### Cloudflare Tunnel

Go back to the main [Cloudflare Dashboard](https://dash.cloudflare.com/) page if not there already.

1. Click Zero Trust
2. Click Networks
3. Create a tunnel
4. Select Cloudflared and click Next
5. Pick any name you would like for your tunnel. Example: rf-yourdomain
6. Save tunnel
7. Select Docker under choose your environment
8. Copy the whole 'docker run cloudflare' command and paste it into a notepad
9. Click Next

!!! note
    Ensure you have copied the whole token. We will need it later in the configuration script.

#### Configure both public hostnames.

???+ info "Public Hostnames"

    !!! tip

        The Service URL must be set to the NGINX container_name in the compose.yaml which is 'nginx' by default.

    ???+ info "**First public hostname with BLANK subdomain**"

        !!! warning inline end

            You may receive an error if you already have DNS records. You will need to delete any existing A or CNAME records pointing to * or yourdomain.com

        - Subdomain: `leave it blank`

        - Domain: `yourdomain.com`

        - Service Type: **HTTPS**

        - Service URL: `nginx`

        Click Additional application settings -> TLS

        === "TLS"

            - Origin Server name: `*.yourdomain.com`

            - HTTP2 connection: **On**

        Click Save tunnel

        ![tunnel_public_hostname_page_settings](https://github.com/user-attachments/assets/934a26aa-7f68-4f6e-b5bc-8cb515de91cb)

    1. Click the newly created tunnel and click Edit.

    2. Click Public Hostname

    3. Click + Add a public hostname

    ???+ info "**Second public hostname with * WILDCARD subdomin**"

        !!! note inline end
        
            Ignore the warning about 'This domain contains a wildcard." We will manually add the wildcard entry under the DNS settings later.

        - Subdomain: `*`

        - Domain: `yourdomain.com`

        - Service Type: **HTTPS**

        - Service URL: `nginx`

        Click Additional application settings -> TLS

        === "TLS"

            - Origin Server name: `.yourdomain.com`

            - HTTP2 connection: **On**

        Click Save hostname

        ![tunnel_public_hostname_page_settings_wildcard](https://github.com/user-attachments/assets/1698a66f-6c13-4b62-9c82-ae4fbcf697e0)

#### **Catch-all rule**

1. Click *Edit* to the right of the catch-all rule.

2. Type or paste `https://nginx` and click *Save*.

![tunnel_public_hostname_config](https://github.com/user-attachments/assets/b3f1ed8f-b75b-490f-abb6-1b5ec3cf3e7d)

### DNS

With the Cloudflare tunnel configuration completed. Go back to the main [Cloudflare Dashboard](https://dash.cloudflare.com/).

1. Click yourdomain.com

2. Select DNS -> Records

You should see a CNAME record that was created automatically for the tunnel.

!!! example "Example tunnel DNS record"

    | Type  | Name             | Content                                                    |
    |-------|------------------|------------------------------------------------------------|
    | CNAME | `yourdomain.com` | `248a0b11-e62a-4b0e-8e30-123456789101112.cfargotunnel.com` |

Click + Add Record and add it as below, substiting yourdomain.com for your domain name.

=== "Add record"

    | Type | Name | Target           |
    | ---- | ---- | ---------------- |
    | CNAME| `*`  | `yourdomain.com` |

Click Save

Now you should have two DNS records.

Both should be proxied.

!!! example "Example DNS records"

    | Type  | Name             | Content                                                    |
    |-------|------------------|------------------------------------------------------------|
    | CNAME | `*`              | `yourdomain.com`                                           |
    | CNAME | `yourdomain.com` | `248a0b11-e62a-4b0e-8e30-123456789101112.cfargotunnel.com` |

    ![DNS_Records_Argo_tunnel_config](https://github.com/user-attachments/assets/64841499-c215-4bec-8392-dd6edfefbac5)

Scroll down and you should see the Cloudflare Nameservers.

Ensure that you are using these name servers with your domain name registrar/provider.

Next is Remote Falcon [installation](../install/remotefalcon.md).