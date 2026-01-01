# PostgreSQL Repmgr Docker Image

This Docker image provides PostgreSQL 18 with repmgr 5.4.0 for PostgreSQL replication management, built on Debian Trixie. It supports both standalone usage and Kubernetes integration for automatic failover.

## Features

- PostgreSQL 18 with repmgr 5.4.0 extension
- Debian Trixie base image
- Multiple execution modes for different use cases
- Kubernetes-native sidecar support
- Automatic PostgreSQL initialization
- Repmgr configuration templating
- Service updater for Kubernetes service selector management

## Execution Modes

The container supports different modes via command arguments:

### Standalone Mode (Development/Testing)
```bash
docker run -d --name repmgr repmgr:debian-trixie standalone
```

### Kubernetes Integration Modes

#### Init Container Mode
Used for registering master/replica nodes during pod initialization:
```bash
# As init container command
command: ["/usr/local/bin/entrypoint.sh", "init"]
```

#### Repmgrd Sidecar Mode
Runs the repmgr daemon for monitoring and failover:
```bash
# As sidecar container command
command: ["/usr/local/bin/entrypoint.sh", "repmgrd"]
```

#### Service Updater Sidecar Mode
Updates Kubernetes service selectors during failover:
```bash
# As sidecar container command
command: ["/usr/local/bin/entrypoint.sh", "service-updater"]
```

## Building the Image

```bash
# Build the Docker image
docker build -t repmgr:debian-trixie .
```

## Environment Variables

### For Init Container Mode
- `NODE_ID`: Unique node ID (required)
- `NODE_NAME`: Node hostname (defaults to `$(hostname)`)
- `NODE_TYPE`: `master`, `standby`, or `witness`
- `UPSTREAM_NODE_ID`: Upstream node ID for standby registration
- `REPMGR_DB`: Repmgr database name (default: `repmgr`)
- `REPMGR_USER`: Repmgr user (default: `repmgr`)
- `REPMGR_PASSWORD`: Repmgr password (default: `repmgr`)

### For Service Updater Mode
- `NAMESPACE`: Kubernetes namespace (default: `default`)
- `MASTER_SERVICE`: Name of master service to update (default: `postgresql-master`)
- `MONITORING_INTERVAL`: Check interval in seconds (default: `30`)


### Master StatefulSet
```yaml
# In postgresql-master-statefulset.yaml
spec:
  template:
    spec:
      initContainers:
      - name: repmgr-init
        image: repmgr:debian-trixie
        command: ["/usr/local/bin/entrypoint.sh", "init"]
        env:
        - name: NODE_TYPE
          value: "master"
        - name: NODE_ID
          value: "1"
      containers:
      - name: postgresql
        # ... postgresql container config
      - name: repmgrd
        image: repmgr:debian-trixie
        command: ["/usr/local/bin/entrypoint.sh", "repmgrd"]
      - name: service-updater
        image: repmgr:debian-trixie
        command: ["/usr/local/bin/entrypoint.sh", "service-updater"]
        env:
        - name: NAMESPACE
          valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
```

### Replica StatefulSet
```yaml
# In postgresql-replica-statefulset.yaml
spec:
  template:
    spec:
      initContainers:
      - name: repmgr-init
        image: repmgr:debian-trixie
        command: ["/usr/local/bin/entrypoint.sh", "init"]
        env:
        - name: NODE_TYPE
          value: "standby"
        - name: UPSTREAM_NODE_ID
          value: "1"
      containers:
      - name: postgresql
        # ... postgresql container config
      - name: repmgrd
        image: repmgr:debian-trixie
        command: ["/usr/local/bin/entrypoint.sh", "repmgrd"]
      - name: service-updater
        image: repmgr:debian-trixie
        command: ["/usr/local/bin/entrypoint.sh", "service-updater"]
```

## Volumes

- `/var/lib/postgresql/data`: PostgreSQL data directory
- `/var/log/repmgr`: Repmgr log files
- `/etc/repmgr`: Repmgr configuration directory

## Ports

- `5432`: PostgreSQL port

## Managing Replication

### Check cluster status
```bash
repmgr cluster show
```

### Check node status
```bash
repmgr node status
```

### Manual failover
```bash
repmgr standby promote --node-id=<node-id>
```

### Rejoin failed master
```bash
repmgr node rejoin --node-id=<node-id>
```

## Security Considerations

- Change default passwords in production
- Use Kubernetes secrets for sensitive environment variables
- Configure proper RBAC for service updater sidecar
- Restrict network policies for inter-pod communication
- Use TLS for PostgreSQL connections in production

## Troubleshooting

### Check container logs
```bash
docker logs <container-name>
```

### Check repmgr logs
```bash
docker exec <container-name> tail -f /var/log/repmgr/repmgr.log
```

### Connect to PostgreSQL
```bash
docker exec -it <container-name> psql -U postgres -d postgres
```

### Check repmgr status
```bash
docker exec <container-name> repmgr cluster show
```

### Kubernetes troubleshooting
```bash
# Check pod status
kubectl get pods

# Check service selector
kubectl get service <service-name> -o yaml

# Check repmgr configuration
kubectl exec <pod-name> -- cat /etc/repmgr/repmgr.conf
```

## Compatibility

- PostgreSQL 18
- repmgr 5.4.0
- Debian Trixie
- Kubernetes 1.19+