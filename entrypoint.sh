#!/bin/bash
set -e

SCRIPT_NAME=${1:-default}

case "$SCRIPT_NAME" in
    "postgres")
        export PATH=$PATH:/usr/lib/postgresql/18/bin
        PGDATA=${PGDATA:-/var/lib/postgresql/data/pgdata}
        export PGDATA

        if [ "$(id -u)" = "0" ]; then
            exec gosu postgres "$0" "$@"
        fi

        if [ ! -s "$PGDATA/PG_VERSION" ]; then
            echo "Initializing PostgreSQL database..."
            initdb -D "$PGDATA" --auth-local=trust --auth-host=md5

            cat >> "$PGDATA/postgresql.conf" << EOF
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB
hot_standby = on
hot_standby_feedback = on
listen_addresses = '*'
shared_preload_libraries = 'repmgr'
EOF

            if [ "${PGBACKREST_ENABLED:-}" = "true" ]; then
                cat >> "$PGDATA/postgresql.conf" << PGBR
archive_mode = on
archive_command = 'pgbackrest --stanza=${PGBACKREST_STANZA:-db} archive-push %p'
PGBR
            fi

            cat > "$PGDATA/pg_hba.conf" << EOF
local   all             all                                     trust
local   replication     all                                     trust
host    all             all             127.0.0.1/32            trust
host    replication     all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    replication     all             10.0.0.0/8              trust
host    all             all             10.0.0.0/8              trust
host    replication     all             0.0.0.0/0               md5
host    all             all             0.0.0.0/0               md5
EOF

            pg_ctl -D "$PGDATA" -w start

            REPMGR_USER=${REPMGR_USER:-repmgr}
            REPMGR_PASSWORD=${REPMGR_PASSWORD:?REPMGR_PASSWORD is required}
            REPMGR_DB=${REPMGR_DB:-repmgr}
            POSTGRES_USER=${POSTGRES_USER:-postgres}
            POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
            POSTGRES_DB=${POSTGRES_DB:-postgres}

            psql -U postgres -d postgres -c "CREATE DATABASE ${POSTGRES_DB};" 2>/dev/null || true
            psql -U postgres -d postgres -c "CREATE USER ${POSTGRES_USER} WITH SUPERUSER PASSWORD '${POSTGRES_PASSWORD}';" 2>/dev/null || true
            psql -U postgres -d postgres -c "ALTER USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';" 2>/dev/null || true

            psql -U postgres -d postgres -c "CREATE DATABASE ${REPMGR_DB};" 2>/dev/null || true
            psql -U postgres -d postgres -c "CREATE USER ${REPMGR_USER} WITH SUPERUSER PASSWORD '${REPMGR_PASSWORD}';" 2>/dev/null || true
            psql -U postgres -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${REPMGR_DB} TO ${REPMGR_USER};" 2>/dev/null || true
            psql -U postgres -d ${REPMGR_DB} -c "CREATE EXTENSION IF NOT EXISTS repmgr;" 2>/dev/null || true

            pg_ctl -D "$PGDATA" -w stop

            echo "PostgreSQL initialization complete"
        fi

        echo "Starting PostgreSQL..."
        exec postgres -D "$PGDATA"
        ;;
    "init")
        exec /usr/local/bin/init-repmgr.sh
        ;;
    "repmgrd")
        exec /usr/local/bin/repmgrd-entrypoint.sh
        ;;
    "service-updater")
        exec /usr/local/bin/service-updater.sh
        ;;
    *)
        echo "Usage: $0 {postgres|init|repmgrd|service-updater}"
        exit 1
        ;;
esac
