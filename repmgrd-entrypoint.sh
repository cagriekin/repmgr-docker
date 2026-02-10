#!/bin/bash
set -e

if [ "$(id -u)" = "0" ]; then
    exec gosu postgres "$0" "$@"
fi

if [ ! -f /etc/repmgr/repmgr.conf ]; then
    echo "ERROR: repmgr.conf not found at /etc/repmgr/repmgr.conf"
    exit 1
fi

PGDATA=${PGDATA:-/var/lib/postgresql/data/pgdata}

echo "Waiting for local PostgreSQL..."
for i in $(seq 1 120); do
    if pg_isready -h 127.0.0.1 -p 5432 > /dev/null 2>&1; then
        echo "PostgreSQL is ready"
        break
    fi
    if [ "$i" = "120" ]; then
        echo "ERROR: Timed out waiting for local PostgreSQL"
        exit 1
    fi
    sleep 2
done

IN_RECOVERY=$(psql -h 127.0.0.1 -U postgres -d postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | xargs)

if [ "$IN_RECOVERY" = "f" ]; then
    echo "Registering primary node..."
    repmgr -f /etc/repmgr/repmgr.conf primary register --force
    echo "Primary registered"
else
    echo "Registering standby node..."
    for attempt in $(seq 1 30); do
        if repmgr -f /etc/repmgr/repmgr.conf standby register --force 2>/dev/null; then
            echo "Standby registered"
            break
        fi
        if [ "$attempt" = "30" ]; then
            echo "ERROR: Failed to register standby after 30 attempts"
            exit 1
        fi
        sleep 5
    done
fi

echo "Starting repmgrd daemon..."

cleanup() {
    kill -TERM $REPMGRD_PID 2>/dev/null || true
    wait $REPMGRD_PID 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

repmgrd -f /etc/repmgr/repmgr.conf --daemonize=no &
REPMGRD_PID=$!

echo "repmgrd started with PID: $REPMGRD_PID"

wait $REPMGRD_PID
