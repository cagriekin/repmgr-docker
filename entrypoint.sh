#!/bin/bash
set -e

# Main entrypoint script for repmgr Docker container
# Supports different execution modes for Kubernetes integration

SCRIPT_NAME=${1:-default}

case "$SCRIPT_NAME" in
    "init")
        # Used as init container for repmgr registration
        exec /usr/local/bin/init-repmgr.sh
        ;;
    "repmgrd")
        # Used as sidecar for running repmgrd daemon
        exec /usr/local/bin/repmgrd-entrypoint.sh
        ;;
    "service-updater")
        # Used as sidecar for Kubernetes service updates
        exec /usr/local/bin/service-updater.sh
        ;;
    "standalone"|"default")
        # Standalone mode for development/testing
        export PGDATA=/var/lib/postgresql/data
        export PATH=$PATH:/usr/lib/postgresql/18/bin

        # Switch to postgres user for database operations
        if [ "$(id -u)" = "0" ]; then
            exec gosu postgres "$0" "$@"
        fi

        # Initialize PostgreSQL if needed
        if [ ! -s "$PGDATA/PG_VERSION" ]; then
            echo "Initializing PostgreSQL database..."
            initdb -D "$PGDATA" --auth-local=trust --auth-host=md5

            # Configure PostgreSQL for replication
            cat >> "$PGDATA/postgresql.conf" << EOF
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB
hot_standby = on
hot_standby_feedback = on
listen_addresses = '*'
shared_preload_libraries = 'repmgr'
EOF

            # Replace pg_hba.conf for replication (complete replacement)
            cat > "$PGDATA/pg_hba.conf" << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Allow connections from localhost during setup
host    all             all             127.0.0.1/32           trust
host    all             all             ::1/128                trust

# Allow local connections
local   all             postgres                                trust
local   all             all                                     trust

# Replication connections
host    replication     repmgr          0.0.0.0/0               md5
host    repmgr          repmgr          0.0.0.0/0               md5

# Default rule
host    all             all             0.0.0.0/0               md5
EOF
        fi

        # Start PostgreSQL
        echo "Starting PostgreSQL..."
        pg_ctl -D "$PGDATA" -l "$PGDATA/postgresql.log" start
        sleep 5

        # Setup repmgr database and user
        echo "Setting up repmgr..."
        psql -h localhost -p 5432 -U postgres -d postgres -c "CREATE DATABASE repmgr;" 2>/dev/null || true
        psql -h localhost -p 5432 -U postgres -d postgres -c "CREATE USER repmgr WITH SUPERUSER PASSWORD 'repmgr';" 2>/dev/null || true
        psql -h localhost -p 5432 -U postgres -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE repmgr TO repmgr;" 2>/dev/null || true

        # Generate basic repmgr config (use postgres db initially for registration)
        cat > /etc/repmgr/repmgr.conf << EOF
node_id=1
node_name=node1
conninfo='host=127.0.0.1 port=5432 user=postgres dbname=postgres connect_timeout=10'
data_directory='$PGDATA'
pg_bindir='/usr/lib/postgresql/18/bin'
replication_user='repmgr'
replication_type='physical'
failover='automatic'
promote_command='repmgr standby promote -f /etc/repmgr/repmgr.conf'
follow_command='repmgr standby follow -f /etc/repmgr/repmgr.conf --upstream-node-id=%n'
monitoring_history=true
log_file='/var/log/repmgr/repmgr.log'
log_level=INFO
log_status_interval=10
EOF

        # Create repmgr extension
        psql -h localhost -p 5432 -U postgres -d repmgr -c "CREATE EXTENSION IF NOT EXISTS repmgr;" 2>/dev/null || true

        # Register primary node (repmgr will create the necessary metadata)
        echo "Registering primary node..."
        repmgr -f /etc/repmgr/repmgr.conf primary register --force 2>/dev/null || repmgr -f /etc/repmgr/repmgr.conf primary register

        echo "Repmgr container is ready (standalone mode)"
        tail -f "$PGDATA/postgresql.log"
        ;;
    *)
        echo "Usage: $0 {init|repmgrd|service-updater|standalone}"
        echo "  init          - Initialize repmgr (for init containers)"
        echo "  repmgrd       - Run repmgrd daemon (for sidecars)"
        echo "  service-updater - Run service updater (for sidecars)"
        echo "  standalone    - Run complete setup (for development)"
        exit 1
        ;;
esac