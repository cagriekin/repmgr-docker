#!/bin/bash
set -e

# Entrypoint script for running repmgrd daemon as a sidecar container
# This handles failover monitoring and promotion

# Switch to postgres user for database operations
if [ "$(id -u)" = "0" ]; then
    echo "Running as root, switching to postgres user..."
    exec gosu postgres "$0" "$@"
else
    echo "Already running as user: $(id -u)"
fi

# Ensure repmgr configuration exists
if [ ! -f /etc/repmgr/repmgr.conf ]; then
    echo "Error: repmgr.conf not found at /etc/repmgr/repmgr.conf"
    echo "This script should be run after init-repmgr.sh has generated the configuration"
    exit 1
fi

echo "Starting repmgrd daemon..."

# Set up signal handling for graceful shutdown
cleanup() {
    echo "Stopping repmgrd daemon..."
    kill -TERM $REPMGRD_PID 2>/dev/null || true
    wait $REPMGRD_PID 2>/dev/null || true
    echo "Repmgrd daemon stopped"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Start repmgrd daemon in background
repmgrd -f /etc/repmgr/repmgr.conf --daemonize=no &
REPMGRD_PID=$!

echo "Repmgrd daemon started with PID: $REPMGRD_PID"

# Wait for repmgrd to exit
wait $REPMGRD_PID