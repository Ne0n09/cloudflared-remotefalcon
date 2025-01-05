#!/bin/bash

# I could not get this script to work with allowing a selection and passing it through to toggle the role.
# So with no arguments it will display all shows found and their current showRole(USER/ADMIN)
# Then the script can be re-run with the showSubdomain passed as an argument to toggle the role:
# ./make_admin.sh yoursubdomain

# Function to toggle showRole
toggle_show_role() {
  local selected_show=$1
  sudo docker exec -it mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
      db = db.getSiblingDB(\"remote-falcon\");
      const selectedShow = \"$selected_show\";
      print(\"Attempting to toggle showSubdomain: \" + selectedShow);
      const show = db.show.findOne({ showSubdomain: selectedShow });
      if (show) {
        const newRole = show.showRole === \"ADMIN\" ? \"USER\" : \"ADMIN\";
        db.show.updateOne(
          { showSubdomain: selectedShow },
          { \$set: { showRole: newRole } }
        );
        print(\"Updated showRole for \" + selectedShow + \" to \" + newRole);
        } else {
          print(\"Error: Show not found: \" + selectedShow);
      }
    '"
}

container_name="mongo"

# Check if the container is running
if sudo docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^$container_name$"; then

  # Check if the script is run with showSubdomain as an argument, if so then toggle the show role
  if [ "$#" -eq 1 ]; then
    # Toggle the role for the provided showSubdomain
    toggle_show_role "$1"
    exit 0
  fi

  # Get all showSubdomains and their roles
  echo "The container '$container_name' is running. Retrieving list of showSubdomains and current showRoles from MongoDB..."
  SHOWS=$(sudo docker exec -it mongo bash -c "
    mongosh --quiet 'mongodb://root:root@localhost:27017' --eval '
      db = db.getSiblingDB(\"remote-falcon\");
      const shows = db.show.find({}, { showSubdomain: 1, showRole: 1 }).toArray();
      shows.forEach(show => print(show.showSubdomain + \" - \" + show.showRole));
    '"
  )

  # Check if any shows are found
  if [ -z "$SHOWS" ]; then
    echo "No shows found."
    exit 1
  fi

  # Print the list of shows and their roles
  echo "Available shows and their roles:"
  echo
  echo "  $SHOWS"
  echo

  # Prompt the user to re-run the script with the show subdomain as an argument
  echo "Please re-run the script with the show subdomain as an argument to toggle the role between USER/ADMIN."
  echo "Example: ./make_admin.sh yourshowname"
else
  echo "The container '$container_name' is not running."
fi