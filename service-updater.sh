#!/bin/bash
set -e

# Service updater sidecar script for Kubernetes
# Watches repmgr cluster status and updates service selectors when failover occurs

# Environment variables
NAMESPACE=${NAMESPACE:-default}
MASTER_SERVICE=${MASTER_SERVICE:-postgresql-master}
REPMGR_DB=${REPMGR_DB:-repmgr}
REPMGR_USER=${REPMGR_USER:-repmgr}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-repmgr}
MONITORING_INTERVAL=${MONITORING_INTERVAL:-30}

echo "Starting repmgr service updater sidecar"
echo "Namespace: ${NAMESPACE}"
echo "Master Service: ${MASTER_SERVICE}"
echo "Monitoring Interval: ${MONITORING_INTERVAL}s"

# Function to get current master from repmgr
get_current_master() {
    local max_retries=3
    local retry_count=0

    # List of nodes to try (master first, then replicas)
    local nodes="postgresql-master-0 postgresql-replica-0 postgresql-replica-1 postgresql-replica-2"

    while [ $retry_count -lt $max_retries ]; do
        for node in $nodes; do
            # Check if node is reachable first
            if timeout 5 bash -c "echo > /dev/tcp/${node}/5432" 2>/dev/null; then
                # Try to query repmgr database
                PRIMARY_NODE=$(PGPASSWORD=${REPMGR_PASSWORD} timeout 10 psql -h ${node} -p 5432 -U ${REPMGR_USER} -d ${REPMGR_DB} \
                    -t -c "SELECT node_name FROM repmgr.nodes WHERE type = 'primary' AND active = true LIMIT 1;" 2>/dev/null | xargs)

                # If we got a result, return it
                if [ -n "$PRIMARY_NODE" ] && [ "$PRIMARY_NODE" != "ERROR:" ]; then
                    echo "$PRIMARY_NODE"
                    return 0
                fi
            fi
        done

        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo "Failed to determine master node (attempt $retry_count/$max_retries), retrying in 5 seconds..."
            sleep 5
        fi
    done

    # If we get here, we couldn't find the master
    echo ""
}

# Function to update service selector
update_service_selector() {
    local new_master=$1

    if [ -z "$new_master" ]; then
        echo "Warning: No master node found, skipping service update"
        return 1
    fi

    echo "Updating master service selector to point to: ${new_master}"

    # Get current selector
    CURRENT_SELECTOR=$(kubectl get service ${MASTER_SERVICE} -n ${NAMESPACE} -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}')

    if [ "$CURRENT_SELECTOR" = "$new_master" ]; then
        echo "Service selector already points to ${new_master}, no update needed"
        return 0
    fi

    # Update service selector
    kubectl patch service ${MASTER_SERVICE} -n ${NAMESPACE} --type merge -p "{
        \"spec\": {
            \"selector\": {
                \"statefulset.kubernetes.io/pod-name\": \"${new_master}\"
            }
        }
    }"

    if [ $? -eq 0 ]; then
        echo "Successfully updated service selector to ${new_master}"
    else
        echo "Failed to update service selector"
        return 1
    fi
}

# Function to check if we're running in Kubernetes
is_kubernetes() {
    [ -n "$KUBERNETES_SERVICE_HOST" ]
}

# Main monitoring loop
if ! is_kubernetes; then
    echo "Not running in Kubernetes, service updater exiting"
    exit 0
fi

LAST_MASTER=""
echo "Starting repmgr cluster monitoring..."

CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5

while true; do
    CURRENT_MASTER=$(get_current_master)

    if [ -n "$CURRENT_MASTER" ] && [ "$CURRENT_MASTER" != "$LAST_MASTER" ]; then
        echo "Master node change detected: ${LAST_MASTER} -> ${CURRENT_MASTER}"
        if update_service_selector "$CURRENT_MASTER"; then
            LAST_MASTER="$CURRENT_MASTER"
            CONSECUTIVE_FAILURES=0
        fi
    elif [ -z "$CURRENT_MASTER" ]; then
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        # Only log warning every 5 consecutive failures to reduce noise
        if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
            echo "Warning: Could not determine current master node (failed $CONSECUTIVE_FAILURES times)"
            CONSECUTIVE_FAILURES=0  # Reset counter to avoid spamming logs
        fi
    else
        # Success case - reset failure counter
        CONSECUTIVE_FAILURES=0
    fi

    sleep ${MONITORING_INTERVAL}
done