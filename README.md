# podman_compose

Puppet module to install podman-compose, build compose files from Hiera data, and manage them as systemd services — supporting both rootless and rootful operation.

## Features

- **Hiera-driven**: Define entire compose stacks as Hiera hashes — no templates to maintain
- **Rootless & rootful**: Automatic user management with `loginctl enable-linger` for rootless
- **Systemd integration**: Each project gets its own systemd service (system or user unit)
- **Rolling updates**: Compose file or `.env` changes trigger `podman-compose up -d` directly — only services with actual changes are recreated, the rest keep running
- **Image-digest drift detection**: On every Puppet run, each service's running container image digest is compared against the desired image. Drift (registry update behind a stable tag, manual change, missing container, …) triggers a per-service `up -d`
- **Image pull on start**: Optionally pull images before every (re)start
- **Secrets support**: Sensitive `.env` values via `Sensitive[String]` (eyaml-friendly)
- **Clean teardown**: `ensure => absent` runs `podman-compose down` and removes all artifacts

## Requirements

- Puppet 7 or 8
- puppetlabs-stdlib >= 8.0.0

## Quick Start

### 1. Include the class

```puppet
include podman_compose
```

### 2. Define projects in Hiera

```yaml
podman_compose::projects:
  traefik:
    rootless: false
    pull_on_start: true
    compose:
      services:
        traefik:
          image: "traefik:v3.1"
          command:
            - "--api.insecure=true"
            - "--providers.docker=true"
            - "--providers.docker.exposedbydefault=false"
            - "--entryPoints.web.address=:80"
            - "--entryPoints.websecure.address=:443"
          ports:
            - "80:80"
            - "443:443"
            - "8080:8080"
          volumes:
            - "/run/podman/podman.sock:/var/run/docker.sock:ro"
            - "./acme:/acme"
          restart: unless-stopped
```

### 3. Run Puppet

```bash
puppet apply -e 'include podman_compose'
```

This will:
1. Install podman and podman-compose
2. Create `/opt/compose/traefik/compose.yml`
3. Create and enable `podman-compose-traefik.service`
4. Pull images and start the stack

## Usage Examples

### Rootless project with .env secrets

```yaml
podman_compose::projects:
  webapp:
    user: webapp
    rootless: true
    env_vars:
      APP_ENV: production
      APP_PORT: '3000'
    env_secrets:
      DB_PASSWORD: ENC[PKCS7,MIIBmQ...]
      SECRET_KEY:  ENC[PKCS7,MIIBqA...]
    compose:
      services:
        app:
          image: "ghcr.io/myorg/webapp:latest"
          ports:
            - "3000:3000"
          env_file:
            - .env
          volumes:
            - "app_data:/app/data"
          restart: unless-stopped
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
            interval: "30s"
            timeout: "5s"
            retries: 3
        redis:
          image: "redis:7-alpine"
          volumes:
            - "redis_data:/data"
          restart: unless-stopped
      volumes:
        app_data: {}
        redis_data: {}
```

This creates:
- System user `webapp` with linger enabled
- `/home/webapp/compose/webapp/compose.yml`
- `/home/webapp/compose/webapp/.env` (mode 0600)
- `~/.config/systemd/user/podman-compose-webapp.service`

### Full stack with networks

```yaml
podman_compose::projects:
  monitoring:
    rootless: false
    compose_dir: /opt/monitoring
    service_timeout: 600
    compose:
      services:
        prometheus:
          image: "prom/prometheus:v2.53.0"
          ports:
            - "9090:9090"
          volumes:
            - "./prometheus.yml:/etc/prometheus/prometheus.yml:ro"
            - "prometheus_data:/prometheus"
          networks:
            - monitoring
          restart: unless-stopped
        grafana:
          image: "grafana/grafana:11.1.0"
          ports:
            - "3000:3000"
          environment:
            GF_SECURITY_ADMIN_PASSWORD: "${GF_ADMIN_PW}"
          volumes:
            - "grafana_data:/var/lib/grafana"
          networks:
            - monitoring
          depends_on:
            - prometheus
          restart: unless-stopped
        node-exporter:
          image: "prom/node-exporter:v1.8.1"
          ports:
            - "9100:9100"
          volumes:
            - "/proc:/host/proc:ro"
            - "/sys:/host/sys:ro"
            - "/:/rootfs:ro"
          command:
            - "--path.procfs=/host/proc"
            - "--path.sysfs=/host/sys"
            - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"
          networks:
            - monitoring
          restart: unless-stopped
      volumes:
        prometheus_data: {}
        grafana_data: {}
      networks:
        monitoring:
          driver: bridge
    env_secrets:
      GF_ADMIN_PW: ENC[PKCS7,MIIBiQ...]
```

### Custom compose directory and extra systemd options

```yaml
podman_compose::projects:
  database:
    rootless: false
    compose_dir: /srv/database
    pull_on_start: false
    extra_systemd_config:
      LimitNOFILE: '65536'
      LimitNPROC: '4096'
    compose:
      services:
        mariadb:
          image: "mariadb:10.11"
          ports:
            - "127.0.0.1:3306:3306"
          volumes:
            - "db_data:/var/lib/mysql"
            - "./conf.d:/etc/mysql/conf.d:ro"
          environment:
            MARIADB_ROOT_PASSWORD_FILE: /run/secrets/db_root_pw
          restart: unless-stopped
      volumes:
        db_data:
          driver: local
```

### Removing a project

```yaml
podman_compose::projects:
  old_app:
    ensure: absent
    rootless: false
    compose:
      services:
        dummy:
          image: "dummy"
```

Setting `ensure: absent` will:
1. Run `podman-compose down --remove-orphans`
2. Remove the systemd unit
3. Remove the compose directory

## Parameters

### Class: `podman_compose`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `manage_package` | `Boolean` | `true` | Manage podman package |
| `podman_package` | `String` | `'podman'` | Podman package name |
| `compose_install_method` | `Enum['package','pip']` | OS-dependent | How to install podman-compose |
| `compose_package` | `String` | `'podman-compose'` | Package name (apt/dnf) |
| `compose_pip_package` | `String` | `'podman-compose'` | Pip package name |
| `compose_ensure` | `String` | `'present'` | Package ensure state |
| `compose_binary` | `Stdlib::Absolutepath` | OS-dependent | Path to binary |
| `projects` | `Hash` | `{}` | Hash of project definitions |

### Defined type: `podman_compose::project`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `compose` | `Hash` | *required* | Compose file as Hash (needs `services` key) |
| `ensure` | `Enum['running','stopped','absent']` | `'running'` | Project state |
| `rootless` | `Boolean` | `true` | Rootless mode |
| `user` | `String` | *required if rootless* | System user |
| `group` | `String` | `$user` | Primary group |
| `manage_user` | `Boolean` | `true` | Manage user resource |
| `compose_dir` | `Stdlib::Absolutepath` | auto | Project directory |
| `env_vars` | `Hash[String, String]` | `{}` | Environment variables for `.env` |
| `env_secrets` | `Hash[String, Sensitive]` | `{}` | Sensitive env vars for `.env` |
| `pull_on_start` | `Boolean` | `true` | Pull images on start |
| `compose_file_name` | `String` | `'compose.yml'` | Compose filename (set to `'docker-compose.yml'` for the legacy name) |
| `service_timeout` | `Integer[60]` | `300` | Systemd start timeout |
| `extra_systemd_config` | `Hash` | `{}` | Extra `[Service]` directives |
| `registries` | `Hash` | `{}` | `server => {username, password}` for `podman login` |
| `manage_search_registries` | `Boolean` | `true` | Manage the user's `registries.conf` so unqualified image names resolve (Podman has no implicit docker.io default) |
| `search_registries` | `Array[String]` | `['docker.io']` | Registries for resolving unqualified image names; shared per user |
| `verify_running_image` | `Boolean` | `true` | On each Puppet run, compare running image digest vs desired and roll affected services if drifted |
| `recreate_strategy` | `Enum['rolling','force-recreate','down-up']` | `'force-recreate'` | How containers are re-created on compose/`.env` change (see below) |

### Unqualified image names (short names)

Unlike Docker, Podman has no implicit `docker.io` default. On a minimal host an
image reference like `louislam/dockge:nightly` fails with
*"no unqualified-search-registries are defined"*. By default this module manages
the project user's `~/.config/containers/registries.conf` (rootful: `/root/...`)
with `unqualified-search-registries = ["docker.io"]` and
`short-name-mode = "permissive"` so short names resolve unattended.

Set `manage_search_registries: false` to manage that file yourself, or override
`search_registries` (e.g. `['docker.io', 'ghcr.io']`). The file is shared per
user via `ensure_resource`, so all projects of the same user must agree on the
value. This is independent of the `registries` parameter, which only performs
`podman login`.

## How it works

```
Hiera YAML
    │
    ▼
podman_compose::project
    │
    ├── compose.yml               (from compose hash → to_yaml)
    ├── .env                       (from env_vars + env_secrets)
    ├── .puppet-images.txt         (service → image map for drift check)
    ├── .puppet-verify-images.sh   (drift check + rolling update helper)
    └── systemd unit
         ├── ExecStartPre: podman-compose pull
         ├── ExecStart:    podman-compose up -d
         ├── ExecStop:     podman-compose down
         └── ExecReload:   podman-compose up -d
```

Update flow:

1. **Compose / .env file change** → notify → re-create according to `recreate_strategy`.
   The default `force-recreate` runs `podman-compose up -d --force-recreate --remove-orphans`
   so changes are always applied to the running containers — a plain `up -d` relies on
   podman-compose's own change detection and can leave containers running with **stale
   `.env` values** (when the env is delivered via an `env_file:` directive) and never
   re-creates an already-existing network.

   `recreate_strategy` controls the trade-off:

   | Value | Command | Use when |
   |---|---|---|
   | `force-recreate` *(default)* | `up -d --force-recreate --remove-orphans` | You want env / config changes applied cleanly with minimal fuss. Re-creates every container; does **not** re-create existing network definitions (subnet/driver). |
   | `down-up` | `down` then `up -d --remove-orphans` | You change **network topology** (subnet, driver, options). Tears the whole project down — including its networks — and brings it back up. Causes a brief project downtime. |
   | `rolling` | `up -d --remove-orphans` | Least disruptive. Only services whose image/config podman-compose detects as changed are re-created. May miss `env_file:` content changes and network changes. |
2. **Drift check on every Puppet run** (when `verify_running_image: true`):
   the helper script does a quiet `podman-compose pull`, then for each service
   compares the running container's image digest (`podman inspect -f '{{.Image}}'`)
   to the desired image's digest (`podman image inspect -f '{{.Id}}'`). If any
   service has drifted, `podman-compose up -d --remove-orphans` is run. This
   catches registry updates behind a stable tag like `:latest` and any out-of-band
   changes.

## Systemd Management

```bash
# Rootful projects
systemctl status podman-compose-traefik
systemctl restart podman-compose-traefik
journalctl -u podman-compose-traefik

# Rootless projects (as the user)
systemctl --user status podman-compose-webapp
systemctl --user restart podman-compose-webapp
journalctl --user -u podman-compose-webapp
```

## License

Apache-2.0
