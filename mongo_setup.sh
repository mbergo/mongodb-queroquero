#!/bin/bash

# Configurations
OLD_CLUSTER_SERVICE="$1"
OLD_CLUSTER_PORT=27017
NEW_CLUSTER_NAMESPACE="default" # Modify if needed
NEW_CLUSTER_POD="mongodb-0" # Primary pod name
NEW_CLUSTER_PORT=27017
DUMP_PATH="/tmp/mongo_backup"
HELM_RELEASE_NAME="my-mongodb"
HELM_CHART_PATH="./mongodb"
VALUES_FILE="values.yaml"

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if required tools are installed
for tool in helm kubectl mongodump mongorestore; do
  if ! command_exists $tool; then
    echo "$tool is not installed. Please install it and rerun the script."
    exit 1
  fi
done

# Step 1: Dump data from the old MongoDB cluster
echo "Dumping data from the old MongoDB cluster at $OLD_CLUSTER_SERVICE:$OLD_CLUSTER_PORT..."
mongodump --host $OLD_CLUSTER_SERVICE --port $OLD_CLUSTER_PORT --out $DUMP_PATH
if [ $? -ne 0 ]; then
  echo "Error during mongodump. Exiting."
  exit 1
fi

echo "Data dumped successfully to $DUMP_PATH."

# Step 2: Install or Upgrade the Helm chart for MongoDB Replica Set
echo "Deploying MongoDB replica set using Helm chart..."
helm upgrade --install $HELM_RELEASE_NAME $HELM_CHART_PATH -f $VALUES_FILE
if [ $? -ne 0 ]; then
  echo "Helm deployment failed. Exiting."
  exit 1
fi

echo "Helm chart deployed successfully."

# Wait for MongoDB pods to become ready
echo "Waiting for the MongoDB primary pod to be ready..."
kubectl wait --for=condition=ready pod/$NEW_CLUSTER_POD --namespace=$NEW_CLUSTER_NAMESPACE --timeout=300s

if [ $? -ne 0 ]; then
  echo "MongoDB pod failed to become ready. Exiting."
  exit 1
fi

echo "MongoDB primary pod is ready."

# Step 3: Restore the data to the new MongoDB cluster
echo "Restoring data to the new MongoDB cluster..."
kubectl exec -i $NEW_CLUSTER_POD --namespace=$NEW_CLUSTER_NAMESPACE -- mongorestore --host localhost --port $NEW_CLUSTER_PORT --drop --dir /data

if [ $? -ne 0 ]; then
  echo "Error during mongorestore. Exiting."
  exit 1
fi

echo "Data restored successfully."

# Step 4: Initialize the MongoDB replica set
echo "Initializing MongoDB replica set..."
kubectl exec $NEW_CLUSTER_POD --namespace=$NEW_CLUSTER_NAMESPACE -- mongo --eval 'rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongodb-0.mongodb-internal.default.svc.cluster.local:27017" }
  ]
})'

if [ $? -ne 0 ]; then
  echo "Replica set initialization failed. Exiting."
  exit 1
fi

echo "MongoDB replica set initialized successfully."

# Step 5: Clean up backup directory
echo "Cleaning up dump files..."
rm -rf $DUMP_PATH

echo "MongoDB setup completed successfully!"
