#!/bin/bash

container_name="mongo"

# Step 1: Check if the container is running
if sudo docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^$container_name$"; then
    echo "The container '$container_name' is running. Retrieving list of shows and roles from MongoDB..."

    # Step 2: Get the list of shows and their roles from MongoDB
    shows=$(sudo docker exec -it mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
        db = db.getSiblingDB(\"remote-falcon\");
        const shows = db.show.find({}, { showName: 1, showRole: 1, _id: 0 }).toArray();
        shows.forEach(doc => {
            const role = doc.showRole ? doc.showRole : \"USER\";
            print(doc.showName + \" (Role: \" + role + \")\");
        });
    '"
    )

    # Step 3: Parse the shows into an array (by line breaks)
    IFS=$'\n' read -r -d '' -a shows_array <<< "$shows"

    # Check if any shows were found
    if [ ${#shows_array[@]} -eq 0 ]; then
        echo "No shows found in MongoDB."
        exit 1
    fi

    # Step 4: Display the shows with their roles
    echo "Configured shows with their roles:"
    for i in "${!shows_array[@]}"; do
        echo "$((i + 1)). ${shows_array[$i]}"
    done

    # Step 5: Ask the user to select a show name
    echo -n "Enter the number of the show name you would like to toggle the role: "
    read selected_index

    # Validate input
    if ! [[ "$selected_index" =~ ^[0-9]+$ ]] || [ "$selected_index" -lt 1 ] || [ "$selected_index" -gt ${#shows_array[@]} ]; then
        echo "Invalid selection. Exiting."
        exit 1
    fi

    # Extract the selected show name
    selected_entry="${shows_array[$((selected_index - 1))]}"
    selected_showname=$(echo "$selected_entry" | sed -E 's/ \(Role:.*$//') # Remove the role information

    # Step 6: Toggle the showRole in MongoDB
    echo "Toggling role for '$selected_showname'..."
    sudo docker exec -it mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
        db = db.getSiblingDB(\"remote-falcon\");
        const selectedShow = \"$selected_showname\".replace(/\"/g, \"\\\"\");
        const show = db.show.findOne({ showName: selectedShow });
        const newRole = show && show.showRole === \"ADMIN\" ? \"USER\" : \"ADMIN\";
        db.show.updateOne(
            { showName: selectedShow },
            { \$set: { showRole: newRole } }
        );
        print(\"Updated showRole for \" + selectedShow + \" to \" + newRole);
    '"
else
    echo "The container '$container_name' is not running."
fi