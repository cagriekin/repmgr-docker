#!/bin/bash
set -e

# Script for initializing repmgr in Kubernetes init containers
# Used for registering master and replica nodes

# Environment variables (can be set via ConfigMap or environment)
NODE_ID=${NODE_ID:-1}
NODE_NAME=${NODE_NAME:-$(hostname)}
CLUSTER_NAME=${CLUSTER_NAME:-pgvector-cluster}
NODE_TYPE=${NODE_TYPE:-master}
UPSTREAM_NODE_ID=${UPSTREAM_NODE_ID:-1}
REPMGR_DB=${REPMGR_DB:-repmgr}
REPMGR_USER=${REPMGR_USER:-repmgr}
REPMGR_PASSWORD=${REPMGR_PASSWORD:-repmgr}

# Generate repmgr configuration
cat > /etc/repmgr/repmgr.conf << EOF
node_id=${NODE_ID}
node_name=${NODE_NAME}
conninfo='host=${NODE_NAME} port=5432 user=${REPMGR_USER} password=${REPMGR_PASSWORD} dbname=${REPMGR_DB} connect_timeout=10'
data_directory='/var/lib/postgresql/data'
pg_bindir='/usr/lib/postgresql/18/bin'
replication_user='${REPMGR_USER}'
replication_type='physical'
failover='automatic'
promote_command='repmgr standby promote -f /etc/repmgr/repmgr.conf'
follow_command='repmgr standby follow -f /etc/repmgr/repmgr.conf --upstream-node-id=%n'
monitoring_history=true
log_file='/var/log/repmgr/repmgr.log'
log_level=INFO
log_status_interval=10
service_start_command='pg_ctl -D /var/lib/postgresql/data start'
service_stop_command='pg_ctl -D /var/lib/postgresql/data stop'
service_restart_command='pg_ctl -D /var/lib/postgresql/data restart'
service_reload_command='pg_ctl -D /var/lib/postgresql/data reload'
EOF

echo "Repmgr configuration generated for ${NODE_TYPE} node: ${NODE_NAME}"

if [ "$NODE_TYPE" = "master" ]; then
    echo "Registering master node..."
    # Wait for PostgreSQL to be ready
    until pg_isready -h localhost -p 5432 -U postgres; do
        echo "Waiting for PostgreSQL..."
        sleep 2
    done

    # Create repmgr database and user if they don't exist
    psql -h localhost -p 5432 -U postgres -d postgres -c "CREATE DATABASE ${REPMGR_DB};" 2>/dev/null || true
    psql -h localhost -p 5432 -U postgres -d postgres -c "CREATE USER ${REPMGR_USER} WITH SUPERUSER PASSWORD '${REPMGR_PASSWORD}';" 2>/dev/null || true
    psql -h localhost -p 5432 -U postgres -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${REPMGR_DB} TO ${REPMGR_USER};" 2>/dev/null || true

    # Create repmgr extension
    psql -h localhost -p 5432 -U postgres -d ${REPMGR_DB} -c "CREATE EXTENSION IF NOT EXISTS repmgr;" 2>/dev/null || true

    # Check if already registered
    if repmgr -f /etc/repmgr/repmgr.conf node status >/dev/null 2>&1; then
        echo "Master node already registered, skipping registration"
    else
        # Register primary node
        repmgr -f /etc/repmgr/repmgr.conf primary register --force || repmgr -f /etc/repmgr/repmgr.conf primary register
        echo "Master node registered successfully"
    fi

elif [ "$NODE_TYPE" = "standby" ]; then
    echo "Registering standby node..."
    # Wait for upstream to be ready
    UPSTREAM_HOST=${UPSTREAM_HOST:-postgresql-master-0}
    until pg_isready -h ${UPSTREAM_HOST} -p 5432 -U ${REPMGR_USER}; do
        echo "Waiting for upstream node ${UPSTREAM_HOST}..."
        sleep 2
    done

    # Check if already registered
    if repmgr -f /etc/repmgr/repmgr.conf node status >/dev/null 2>&1; then
        echo "Standby node already registered, skipping registration"
    else
        # Clone from upstream
        repmgr -h ${UPSTREAM_HOST} -U ${REPMGR_USER} -d ${REPMGR_DB} -f /etc/repmgr/repmgr.conf standby clone --upstream-node-id=${UPSTREAM_NODE_ID}

        # Register standby
        repmgr -f /etc/repmgr/repmgr.conf standby register --upstream-node-id=${UPSTREAM_NODE_ID}
        echo "Standby node registered successfully"
    fi

elif [ "$NODE_TYPE" = "witness" ]; then
    echo "Registering witness node..."
    # Witness registration logic
    repmgr -f /etc/repmgr/repmgr.conf witness register --upstream-node-id=${UPSTREAM_NODE_ID}
    echo "Witness node registered successfully"
fi

echo "Repmgr initialization completed"