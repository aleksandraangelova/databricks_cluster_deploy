#!/bin/bash
set -e

###########################################
# Validate Input Parameters
###########################################
DEPLOYMENT_TARGET=$1
if [[ -z "$DEPLOYMENT_TARGET" ]]; then
  echo "DEPLOYMENT_TARGET is mandatory. Exiting due to lacking target."
  exit 1
fi

###########################################
# Deploy Databricks Bundle
###########################################
echo "Running command: 'databricks bundle deploy -t $DEPLOYMENT_TARGET'"
export DEPLOYMENT_TARGET=${DEPLOYMENT_TARGET}

databricks bundle deploy \
  -p cdpdev \
  -t $DEPLOYMENT_TARGET

###########################################
# Fetch the Latest .whl File from Workspace
###########################################
export LATEST_WHL_FILE=$(databricks api get /api/2.0/workspace/list --json \
    '{"path": "/Workspace/Users/<username>/.bundle/cdpdev/dev/artifacts/.internal"}' | \
  jq -r '.objects | sort_by(.modified_at) | last | .path')

echo "Latest wheel file path: $LATEST_WHL_FILE"

###########################################
# Deploy the Cluster
###########################################
CLUSTER_JSON=$(cat < cluster_template.json)
CLUSTER_NAME=$(echo "${CLUSTER_JSON}" | jq -r '.cluster_name')

# Fetch Existing Cluster ID if Exists
export CLUSTER_ID=$(databricks api get /api/2.0/clusters/list | \
  jq -r '.clusters[] | select(.cluster_name == "'"$CLUSTER_NAME"'").cluster_id')

echo "Cluster ID: $CLUSTER_ID"

###########################################
# Create or Update Cluster
###########################################
if [[ -z "$CLUSTER_ID" ]]; then
  echo "Cluster not found. Creating a new cluster..."
  INITIAL_DEPLOYMENT=true

  export CLUSTER_ID=$(databricks api post /api/2.0/clusters/create \
    --json "$(echo "${CLUSTER_JSON}")" | \
    jq -r '.cluster_id')

  echo "New Cluster created with ID: $CLUSTER_ID"
else
  echo "Existing Cluster found. Uninstalling previously installed libraries..."

  INSTALLED_LIBRARIES=$(databricks api get /api/2.0/libraries/all-cluster-statuses | \
    jq -r '.statuses[] |
          select(.cluster_id == "'"$CLUSTER_ID"'") |
          .library_statuses[] |
          .library.whl')

  # Uninstall all existing .whl libraries
  for library in ${INSTALLED_LIBRARIES[@]}; do
    # Check if the library ends with .whl
    if [[ "$library" == *.whl ]]; then
      echo "Uninstalling wheel library: $library"
      databricks api post /api/2.0/libraries/uninstall \
        --json "{
          \"cluster_id\": \"$CLUSTER_ID\",
          \"libraries\": [{ \"whl\": \"$library\" }]
        }"
    fi
  done

  echo "Updating existing cluster configuration..."
  echo "${CLUSTER_JSON}" | \
    jq --arg CLUSTER_ID "$CLUSTER_ID" '.cluster_id = $CLUSTER_ID' > "TMP"

  databricks api post /api/2.0/clusters/edit \
    --json "$(cat TMP)"

  echo "Cluster configuration updated."
fi

###########################################
# Install the Latest Wheel on the Cluster
###########################################
LIBRARY_INSTALL_JSON=$(envsubst < library_install.json)
echo "Installing latest wheel file"

if [ "$INITIAL_DEPLOYMENT" = true ]; then
  while true; do
    STATUS=$(databricks api get /api/2.0/clusters/get --json "{\"cluster_id\":\"$CLUSTER_ID\"}" | jq -r '.state')
    # Check cluster status and wait if PENDING
    echo "Waiting for cluster $CLUSTER_ID to be in RUNNING state..."
    echo "Cluster status: $STATUS"

    if [ "$STATUS" == "RUNNING" ]; then
      echo "Cluster is now running. Proceeding with library installation."
      break
    elif [ "$STATUS" == "TERMINATED" ] || [ "$STATUS" == "ERROR" ]; then
      echo "Cluster is in an error state: $STATUS"
      exit 1
    fi

    sleep 10
  done
else
  echo "Not an initial deployment. Skipping cluster status check."
fi

databricks api post /api/2.0/libraries/install \
  --json "$(echo "${LIBRARY_INSTALL_JSON}")"

echo "Library installation completed."
