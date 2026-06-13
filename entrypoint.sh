#!/bin/bash
set -e

SCRIPT_NAME=${1:-default}

# Scan sibling StatefulSet pods for an active primary and the newest timeline
# seen. Sets REACHED_ANY/FOUND_PRIMARY/NEWEST_TLI/NEWEST_PEER. Timeline comes
# from the WAL insert position (pg_walfile_name(pg_current_wal_lsn())), which
# reflects a fast promotion immediately -- pg_control_checkpoint() keeps the
# pre-promotion timeline until the spread end-of-recovery checkpoint completes
# (minutes under load), which would let a stale primary slip through.
scan_peers() {
    REACHED_ANY=0; FOUND_PRIMARY=0; NEWEST_TLI=0; NEWEST_PEER=""
    local ru="${REPMGR_USER:-repmgr}" rd="${REPMGR_DB:-repmgr}"
    local ordinal="${HOSTNAME##*-}" base="${HOSTNAME%-*}"
    local node_count="${REPMGR_NODE_COUNT:-10}"
    case "$node_count" in ''|*[!0-9]*) node_count=10 ;; esac
    local i peer in_recovery remote_tli
    for i in $(seq 0 $((node_count - 1))); do
        [ "$i" = "$ordinal" ] && continue
        peer="${base}-${i}.${HEADLESS_SERVICE}"
        PGPASSWORD="$REPMGR_PASSWORD" pg_isready -t 3 -h "$peer" -p 5432 -U "$ru" -d "$rd" >/dev/null 2>&1 || continue
        REACHED_ANY=1
        in_recovery=$(PGPASSWORD="$REPMGR_PASSWORD" psql -tAX -h "$peer" -p 5432 -U "$ru" -d "$rd" -c "SELECT pg_is_in_recovery();" 2>/dev/null) || in_recovery=""
        [ "$in_recovery" = "f" ] || continue
        FOUND_PRIMARY=1
        remote_tli=$(PGPASSWORD="$REPMGR_PASSWORD" psql -tAX -h "$peer" -p 5432 -U "$ru" -d "$rd" -c "SELECT substring(pg_walfile_name(pg_current_wal_lsn()) from 1 for 8)::int;" 2>/dev/null) || remote_tli=""
        case "$remote_tli" in ''|*[!0-9]*) continue ;; esac
        if [ "$remote_tli" -gt "$NEWEST_TLI" ]; then NEWEST_TLI="$remote_tli"; NEWEST_PEER="$peer"; fi
    done
    return 0
}

# Prevent a former primary from resuming read-write on a stale timeline after a
# standby was promoted while this node's CONTAINER (not pod) was down -- the
# init container, which holds the re-clone logic, does not re-run on a
# container-only restart (CrashLoopBackOff, OOM, liveness kill). Repmgr-managed
# nodes only; no-op for standalone use of the image.
primary_safety_guard() {
    [ -f /etc/repmgr/repmgr.conf ] || return 0
    [ -n "${HEADLESS_SERVICE:-}" ] || return 0
    [ -n "${REPMGR_PASSWORD:-}" ] || return 0
    [ -f "$PGDATA/standby.signal" ] && return 0   # already a standby; init/repmgrd own recovery

    local ru="${REPMGR_USER:-repmgr}" rd="${REPMGR_DB:-repmgr}"

    if [ ! -s "$PGDATA/PG_VERSION" ]; then
        # Empty data dir. On a genuine first install no peer is primary yet, so
        # a single fast scan keeps install latency low; if a primary already
        # exists, initdb here would fork a divergent cluster. Auto-cloning an
        # empty ordinal-0 is issue #125; here we refuse rather than diverge.
        scan_peers
        if [ "$FOUND_PRIMARY" = "1" ]; then
            echo "FATAL: data directory is empty but ${NEWEST_PEER:-a peer} is an active primary; refusing to initialize a divergent database. Recreate this pod with persistent storage, or clone it manually." >&2
            exit 1
        fi
        return 0
    fi

    # Existing data that would start read-write. Settle only while NO peer is
    # reachable (correlated restart): if peers answer and none is a newer
    # primary, this node is healthy and starts immediately (no latency added).
    local attempts="${REPMGR_STALE_CHECK_ATTEMPTS:-5}" attempt
    case "$attempts" in ''|*[!0-9]*) attempts=5 ;; esac
    for attempt in $(seq 1 "$attempts"); do
        scan_peers
        [ "$NEWEST_TLI" -gt 0 ] && break
        [ "$REACHED_ANY" = "1" ] && break
        [ "$attempt" -lt "$attempts" ] && { echo "stale-primary guard: no peer reachable yet (attempt ${attempt}/${attempts}); settling 3s" >&2; sleep 3; }
    done

    local local_tli
    local_tli=$(pg_controldata -D "$PGDATA" 2>/dev/null | awk -F: '/Latest checkpoint.s TimeLineID/{gsub(/[^0-9]/,"",$2);print $2}') || local_tli=""
    case "$local_tli" in
        ''|*[!0-9]*)
            if [ "$NEWEST_TLI" -gt 0 ]; then
                echo "FATAL: cannot read local timeline while ${NEWEST_PEER} is an active primary on timeline ${NEWEST_TLI}; refusing to start read-write" >&2
                exit 1
            fi
            return 0 ;;
    esac

    if [ "$NEWEST_TLI" -gt "$local_tli" ]; then
        echo "stale-primary guard: ${NEWEST_PEER} is primary on timeline ${NEWEST_TLI}, local timeline is ${local_tli}; rejoining as standby" >&2
        local conninfo="host=${NEWEST_PEER} port=5432 user=${ru} password=${REPMGR_PASSWORD} dbname=${rd} connect_timeout=10"
        # node rejoin needs a dormant node and rewinds via pg_rewind (PG18
        # initdb enables data checksums, so pg_rewind is available). It starts
        # the node to verify it attaches; stop it afterward so the postmaster
        # can run as the container's main process via the exec below.
        if repmgr -f /etc/repmgr/repmgr.conf node rejoin -d "$conninfo" --force-rewind --config-files=postgresql.conf,pg_hba.conf; then
            pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || true
            echo "stale-primary guard: rejoin complete; starting as standby" >&2
        else
            echo "stale-primary guard: pg_rewind rejoin failed; falling back to full re-clone from ${NEWEST_PEER}" >&2
            pg_ctl -D "$PGDATA" -m immediate -w stop >/dev/null 2>&1 || true
            rm -rf "${PGDATA:?}"/*
            local cloned=0 a
            for a in $(seq 1 5); do
                if PGPASSWORD="$REPMGR_PASSWORD" repmgr -h "$NEWEST_PEER" -U "$ru" -d "$rd" -f /etc/repmgr/repmgr.conf standby clone --force; then cloned=1; break; fi
                echo "stale-primary guard: clone attempt ${a} failed; retrying in 5s" >&2
                sleep 5
            done
            [ "$cloned" = "1" ] || { echo "FATAL: re-clone failed after rejoin failure" >&2; exit 1; }
        fi
    fi
    return 0
}

case "$SCRIPT_NAME" in
    "postgres")
        export PATH=$PATH:/usr/lib/postgresql/18/bin
        PGDATA=${PGDATA:-/var/lib/postgresql/data/pgdata}
        export PGDATA

        if [ "$(id -u)" = "0" ]; then
            exec gosu postgres "$0" "$@"
        fi

        primary_safety_guard

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
host    replication     all             10.0.0.0/8              scram-sha-256
host    all             all             10.0.0.0/8              scram-sha-256
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
