WORK IN PROGRESS

## Health Check script

The health check script runs automatically after the configure-rf script to display and check various things:

- 'sudo docker ps -a' to display the status of all containers.
- curl command is run against each Remote Falcon endpoint and the HTTP response code and endpoint status are displayed along with the endpoint links.
- The certificate and private key are validated with openssl to confirm they match.
- If nginx is running, 'sudo docker exec nginx nginx -t' to test the nginx configuration.
- If mongo is running, any shows that are configured in Remote Falcon will be displayed in the format of https://showname.yourdomain.com
- The main Remote Falcon link is displayed in the format of https://yourdomain.com

```sh
./health_check.sh
```

## Updating or viewing the .env file manually outside of the configuration script

The configuration script isn't required to view or make updates to the .env file. You can manually edit the file, but the compose stack will have to be brought down manually and the Remote Falcon images rebuilt for some settings to take effect.

To view the .env file:

```sh
cat remotefalcon/.env
```

To manually edit the .env file:

```sh
nano remotefalcon/.env
```

## External API

Follow the steps below to get access to the external API for your self hosted RF.

This requires that you have the *external-api* container running.

1. From the Control Panel Dashboard click the *gear* icon on the top right

2. Click *Account*

3. Click *Request Access* to the right of Request API Access

    !!! note

        Ignore the Unexpected Error or API Access Already Requested if you do not have email configured. The API token and secret will still be generated. 

4.  Download the `#!sh generate_jwt.sh` script to your RF server, make it executable, and run it.

    ```sh
    curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/generate_jwt.sh
    chmod +x generate_jwt.sh
    ./generate_jwt.sh
    ```

The script will look for a 'mongo' container and dump out all the API details that it finds in the database.

6. Enter your *apiAccessToken* with no quotes ''

7. Enter your *apiAccessSecret* with no quotes ''

The script will display your JWT that you can use as needed.

You can test your JWT with curl in Linux directly from your RF server.

1. Enter your JWT on the shell to set the JWT variable with: 

    ```sh
    JWT=replace_with_your_JWT
    ```

2. Verify your JWT is set by entering ```$JWT``` on the shell

3. Replace *yourdomain.com* with your RF domain and run the curl command:

    ```sh
    curl -X 'GET' 'https://yourdomain.com/remote-falcon-external-api/showDetails' -H 'accept: application/json' -H "Authorization: Bearer $JWT"
    ```

If all went to plan you will see output similar to the below if you have a freshly configured account.

```json
{"preferences":{"viewerControlEnabled":false,"viewerControlMode":"JUKEBOX","resetVotes":false,"jukeboxDepth":0,"locationCheckMethod":null,"showLatitude":0.0,"showLongitude":0.0,"allowedRadius":1.0,"jukeboxRequestLimit":0,"locationCode":null,"hideSequenceCount":0,"makeItSnow":false},"sequences":[],"sequenceGroups":[],"requests":[],"votes":[],"playingNow":null,"playingNext":null,"playingNextFromSchedule":null}
```

References:

[Remote Falcon SwaggerHub](https://app.swaggerhub.com/apis/whitesoup12/RemoteFalcon)

[Remote Falcon external-api-sample](https://github.com/Remote-Falcon/remote-falcon-issue-tracker/tree/main/external-api-sample)

## Admin access

This will provde a new Admin section on the left-hand menu on the Control Panel. It will let you search for show subdomains and let you basically view/edit the Mongo DB record.

The `#!sh make_admin.sh` script will display any shows found on your RF and whether they are configured as a USER or ADMIN:
   
```sh
curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/make_admin.sh
chmod +x ./make_admin.sh
./make_admin.sh
```

After the running the script and getting the list of shows and their roles you can re-run the script to toggle the show from USER or ADMIN:

```sh
./make_admin.sh yourshowname
```