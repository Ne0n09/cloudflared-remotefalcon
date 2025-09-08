## External API

Follow the steps below to get access to the external API for your self hosted Remote Falcon.

1. From the Control Panel Dashboard click the *gear* icon on the top right

2. Click *Account*

3. Click *Request Access* to the right of Request API Access

    !!! note

        Ignore the Unexpected Error or API Access Already Requested if you do not have email configured. The API token and secret will still be generated. 

4.  Copy the command below and paste it to download and run the [generate_jwt](../scripts/index.md#__tabbed_1_6) script:

    ```sh
    curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/generate_jwt.sh; \
    chmod +x generate_jwt.sh; \
    ./generate_jwt.sh
    ```

    - The script will look for a 'mongo' container and list shows that have requested API access in the database.

    - The script will display your JWT that you can use as needed.

### Testing External API access

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

- [Remote Falcon SwaggerHub](https://app.swaggerhub.com/apis/whitesoup12/RemoteFalcon)

- [Remote Falcon external-api-sample](https://github.com/Remote-Falcon/remote-falcon-issue-tracker/tree/main/external-api-sample)

## Admin access

- This will provde a new Admin section on the left-hand menu on the Control Panel. 

- It will let you search for show subdomains and let you basically view/edit the MongoDB record.

- The [make_admin](../scripts/index.md#__tabbed_1_7) script will display any shows found and whether they are configured as a USER or ADMIN.

- Copy the command below and paste it to download and run the make_admin script:   

    ```sh
    curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/refs/heads/main/make_admin.sh; \
    chmod +x ./make_admin.sh; \
    ./make_admin.sh
    ```

- The script will run and display a list of shows and their roles. 

- Select the number of the show to toggle the role.

- You can re-run the script to toggle the show from USER or ADMIN:

- You may have to log out of Remote Falcon and back in again if you receive Unexpected Error when trying to serach for show subdomains.