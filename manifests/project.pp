# @summary Manage a single podman-compose project
#
# Creates the compose directory, renders the compose file from a Hash,
# optionally manages an .env file, and sets up a systemd service to
# keep the project running.
#
# @param compose
#   The compose file content as a Puppet Hash. Gets rendered to YAML.
#   Must contain at least a 'services' key.
# @param ensure
#   Desired state: 'running', 'stopped', or 'absent'.
# @param rootless
#   Run containers as unprivileged user (true) or as root (false).
# @param user
#   System user owning the project. Required when rootless is true.
# @param group
#   Primary group for the user. Defaults to $user.
# @param manage_user
#   Whether to manage the system user resource.
# @param compose_dir
#   Absolute path to the project directory. Auto-derived if unset.
# @param env_vars
#   Optional Hash of KEY=VALUE pairs written to an .env file.
# @param env_secrets
#   Optional Hash of sensitive KEY=VALUE pairs merged into .env.
#   Values should come from Hiera eyaml or similar.
# @param pull_on_start
#   Pull images before (re)starting the service.
# @param compose_file_name
#   Name of the compose file. Default: compose.yml (the modern Compose Spec
#   name). Set to 'docker-compose.yml' for the legacy filename.
# @param service_timeout
#   Systemd TimeoutStartSec for pull + start.
# @param extra_systemd_config
#   Additional systemd unit directives merged into [Service].
# @param registries
#   Hash of registry server => {username, password} for `podman login`.
#   Credentials are piped via stdin. Change detection via SHA256 sentinel.
# @param verify_running_image
#   On every Puppet run, compare each service's running container image
#   digest with the desired image (after a quiet `pull`). On drift, run
#   `podman-compose up -d --remove-orphans` so only affected services are
#   recreated. Detects manual changes, registry digest updates behind a
#   stable tag (e.g. ':latest'), and missing containers.
# @param recreate_strategy
#   How containers are (re)created when the compose file or .env change.
#   Defaults to 'force-recreate' so env changes are always applied cleanly
#   (a plain `up -d` may leave running containers with stale `env_file:`
#   values). Use 'down-up' when you change network definitions (subnet,
#   driver, options), since `up` alone never re-creates an existing network
#   — at the cost of a brief project downtime. Use 'rolling' for the old,
#   least-disruptive `up -d` behaviour.
#
# @example Hiera definition
#   podman_compose::projects:
#     traefik:
#       rootless: false
#       compose:
#         services:
#           traefik:
#             image: "traefik:v3.1"
#             ports:
#               - "80:80"
#               - "443:443"
#             volumes:
#               - "/var/run/podman/podman.sock:/var/run/docker.sock:ro"
#               - "./config:/etc/traefik:ro"
#             restart: unless-stopped
#
define podman_compose::project (
  Hash                                $compose,
  Podman_compose::Ensure              $ensure              = 'running',
  Boolean                             $rootless            = true,
  Optional[String[1]]                 $user                = undef,
  Optional[String[1]]                 $group               = undef,
  Boolean                             $manage_user         = true,
  Optional[Stdlib::Absolutepath]      $compose_dir         = undef,
  Hash[String[1], String]             $env_vars            = {},
  Hash[String[1], Sensitive[String]]  $env_secrets         = {},
  Boolean                             $pull_on_start       = true,
  String[1]                           $compose_file_name   = 'compose.yml',
  Integer[60]                         $service_timeout     = 300,
  Hash[String, String]                $extra_systemd_config = {},
  Podman_compose::Registries          $registries          = {},
  Boolean                             $verify_running_image = true,
  Podman_compose::Recreate_strategy   $recreate_strategy   = 'force-recreate',
) {
  require podman_compose::install

  # --- Parameter validation & defaults ---

  if $rootless and $user == undef {
    fail("podman_compose::project[${name}]: 'user' is required when rootless is true")
  }

  $_user  = $rootless ? { true => $user, default => 'root' }
  $_group = pick($group, $_user)

  $_compose_dir = $compose_dir ? {
    undef   => $rootless ? {
      true  => "/home/${_user}/${podman_compose::user_compose_dir_name}/${name}",
      false => "${podman_compose::root_compose_dir}/${name}",
    },
    default => $compose_dir,
  }

  $_service_name = "podman-compose-${name}"

  # Compose sub-command(s) run by the rolling-update trigger when the compose
  # file or .env change. A bare `up -d` relies on podman-compose's own change
  # detection, which misses `.env` content delivered via `env_file:` and never
  # re-creates existing networks — hence the configurable strategy.
  $_cb = $podman_compose::compose_binary
  $_recreate_ops = $recreate_strategy ? {
    'rolling'        => "${_cb} -f ${compose_file_name} up -d --remove-orphans",
    'force-recreate' => "${_cb} -f ${compose_file_name} up -d --force-recreate --remove-orphans",
    'down-up'        => "${_cb} -f ${compose_file_name} down && ${_cb} -f ${compose_file_name} up -d --remove-orphans",
  }

  # Validate compose hash has services
  unless 'services' in $compose {
    fail("podman_compose::project[${name}]: 'compose' hash must contain a 'services' key")
  }

  # Helper prefix for rootless systemctl commands.
  # Puppet exec 'environment' arrays don't support shell expansion,
  # so we wrap every rootless systemctl call in bash -c with $(id -u)
  # resolved at runtime by the target user's shell.
  #
  # On a fresh install `loginctl enable-linger` triggers systemd-logind
  # to start the user manager asynchronously, so the user DBus socket
  # at /run/user/<uid>/bus may not exist yet when subsequent
  # `systemctl --user` / `podman-compose` calls run in the same Puppet
  # run. Wait up to ~30s for the bus to appear before continuing —
  # no-op once the socket is ready.
  $_scu = '/usr/bin/bash -c \'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus && for _i in $(seq 1 30); do test -S "$XDG_RUNTIME_DIR/bus" && break; sleep 1; done &&'

  # Guard for rootless `--user` exec calls. If /run/user/<uid>/bus isn't
  # ready yet (very fresh install: linger was just enabled, user manager
  # still spinning up), skip the exec gracefully — Puppet succeeds, and
  # the next run picks it up once the bus is there.
  $_bus_check = "/usr/bin/bash -c 'test -S /run/user/\$(id -u ${_user})/bus'"

  # --- Ensure: absent ---

  # Safe cwd for execs that run as a non-root user. Puppet inherits its agent's
  # cwd (usually /root); without an explicit cwd a non-root `exec` fails with
  # "cannot chdir to /root: Permission denied".
  $_safe_cwd = '/tmp'

  if $ensure == 'absent' {
    # A project created before compose.yml became the default may still carry
    # the legacy 'docker-compose.yml' on disk. Resolve whichever compose file
    # is actually present at teardown time so `down` always runs — otherwise
    # the directory/unit get removed while containers and networks keep
    # running unmanaged.
    $_legacy_compose_file = 'docker-compose.yml'
    $_down_resolve = "_cf=${compose_file_name}; [ -f \"\$_cf\" ] || _cf=${_legacy_compose_file};"
    $_down_exists  = "/usr/bin/bash -c 'test -f ${_compose_dir}/${compose_file_name} || test -f ${_compose_dir}/${_legacy_compose_file}'"

    if $rootless {
      exec { "podman-compose-down-${name}":
        command => "${_scu} ${_down_resolve} ${podman_compose::compose_binary} -f \"\$_cf\" down --remove-orphans'",
        cwd     => $_compose_dir,
        user    => $_user,
        onlyif  => [
          $_down_exists,
          $_bus_check,
        ],
        before  => File[$_compose_dir],
      }

      $_absent_unit_dir = "/home/${_user}/.config/systemd/user"
      file { "${_absent_unit_dir}/${_service_name}.service":
        ensure => absent,
      }
    } else {
      exec { "podman-compose-down-${name}":
        command => "/usr/bin/bash -c '${_down_resolve} ${podman_compose::compose_binary} -f \"\$_cf\" down --remove-orphans'",
        cwd     => $_compose_dir,
        onlyif  => $_down_exists,
        path    => ['/usr/local/bin', '/usr/bin', '/bin'],
        before  => File[$_compose_dir],
      }

      file { "/etc/systemd/system/${_service_name}.service":
        ensure => absent,
        notify => Exec["systemctl-daemon-reload-${name}"],
      }

      exec { "systemctl-daemon-reload-${name}":
        command     => '/usr/bin/systemctl daemon-reload',
        refreshonly => true,
      }
    }

    file { $_compose_dir:
      ensure  => absent,
      recurse => true,
      purge   => true,
      force   => true,
    }
  } else {
    # =========================================================
    # ensure => running | stopped
    # =========================================================

    $_parent_dir = dirname($_compose_dir)

    # --- User management (rootless) ---

    # ensure_resource so the same user can be shared across multiple
    # projects and/or cron jobs without a duplicate declaration error.
    # Ordering is expressed via a chaining arrow (which may appear more
    # than once) rather than a `before` param, so resources sharing the
    # user but with different parent dirs don't clash on ensure_resource's
    # parameter comparison.
    if $rootless and $manage_user {
      ensure_resource('podman_compose::user', $_user)
      Podman_compose::User[$_user] -> File[$_parent_dir]
    }

    # --- Registry logins ---
    # Each registry gets a podman_compose::registry resource.
    # ensure_resource avoids duplicates when multiple projects/cron jobs
    # share the same user and registry. Ordering toward the compose file
    # is expressed via a chaining arrow (which may appear multiple times)
    # rather than a before param, so resources sharing a registry but with
    # different compose dirs don't clash on ensure_resource's parameter
    # comparison.

    $registries.each |String $_server, Hash $_creds| {
      $_safe = regsubst($_server, '[^a-zA-Z0-9._-]', '_', 'G')
      ensure_resource('podman_compose::registry', "${_user}@${_safe}", {
        server   => $_server,
        username => $_creds['username'],
        password => $_creds['password'],
        user     => $_user,
        rootless => $rootless,
      })
      Podman_compose::Registry["${_user}@${_safe}"] -> File["${_compose_dir}/${compose_file_name}"]
    }

    # --- Directory & compose file ---

    # Manage the parent dir so it's owned by the project user (rootless)
    # instead of root:root. ensure_resource avoids duplicates when multiple
    # projects share the same parent (e.g. /home/<user>/compose).
    $_parent_attrs = $rootless ? {
      true  => { owner => $_user, group => $_group, mode => '0750' },
      false => { owner => 'root', group => 'root', mode => '0755' },
    }
    ensure_resource('file', $_parent_dir, { ensure => directory } + $_parent_attrs)

    file { $_compose_dir:
      ensure  => directory,
      owner   => $_user,
      group   => $_group,
      mode    => '0750',
      require => File[$_parent_dir],
    }

    file { "${_compose_dir}/${compose_file_name}":
      ensure  => file,
      owner   => $_user,
      group   => $_group,
      mode    => '0640',
      content => epp('podman_compose/compose.yaml.epp', {
        'compose' => $compose,
      }),
      notify  => Exec["podman-compose-restart-${name}"],
    }

    # --- Environment file (.env) ---

    $_merged_env = $env_vars + $env_secrets.reduce({}) |$memo, $entry| {
      $memo + { $entry[0] => $entry[1].unwrap }
    }

    if ! empty($_merged_env) {
      file { "${_compose_dir}/.env":
        ensure  => file,
        owner   => $_user,
        group   => $_group,
        mode    => '0600',
        content => epp('podman_compose/env_file.epp', {
          'env_vars' => $_merged_env,
        }),
        notify  => Exec["podman-compose-restart-${name}"],
      }
    }

    # --- Systemd service ---

    if $rootless {
      # ── Rootless: systemd user unit ──

      $_user_unit_dir = "/home/${_user}/.config/systemd/user"

      exec { "mkdir-systemd-user-${name}":
        command => "/usr/bin/mkdir -p ${_user_unit_dir}",
        creates => $_user_unit_dir,
        user    => $_user,
        cwd     => $_safe_cwd,
      }

      file { "${_user_unit_dir}/${_service_name}.service":
        ensure  => file,
        owner   => $_user,
        group   => $_group,
        mode    => '0644',
        content => epp('podman_compose/systemd_user_unit.epp', {
          'project_name'         => $name,
          'compose_dir'          => $_compose_dir,
          'compose_binary'       => $podman_compose::compose_binary,
          'compose_file_name'    => $compose_file_name,
          'pull_on_start'        => $pull_on_start,
          'service_timeout'      => $service_timeout,
          'extra_systemd_config' => $extra_systemd_config,
        }),
        notify  => Exec["systemd-user-reload-${name}"],
        require => Exec["mkdir-systemd-user-${name}"],
      }

      exec { "systemd-user-reload-${name}":
        command     => "${_scu} /usr/bin/systemctl --user daemon-reload'",
        user        => $_user,
        cwd         => $_safe_cwd,
        onlyif      => $_bus_check,
        refreshonly => true,
      }

      exec { "systemd-user-enable-${name}":
        command => "${_scu} /usr/bin/systemctl --user enable ${_service_name}.service'",
        user    => $_user,
        cwd     => $_safe_cwd,
        onlyif  => $_bus_check,
        unless  => "${_scu} /usr/bin/systemctl --user is-enabled ${_service_name}.service'",
        require => [
          File["${_user_unit_dir}/${_service_name}.service"],
          Exec["systemd-user-reload-${name}"],
        ],
      }

      # Files that must exist before the unit is started: starting the
      # service runs `podman-compose … up -d`, which reads the compose file
      # (and .env). Unlike the rootful Service, the user-unit start exec has
      # no implicit edge to these files, so declare it explicitly — otherwise
      # the start (or the drift-check that requires it) can run before the
      # compose file is written, failing with "missing files".
      $_runtime_files = empty($_merged_env) ? {
        true    => [File["${_compose_dir}/${compose_file_name}"]],
        default => [
          File["${_compose_dir}/${compose_file_name}"],
          File["${_compose_dir}/.env"],
        ],
      }

      if $ensure == 'running' {
        exec { "systemd-user-start-${name}":
          command => "${_scu} /usr/bin/systemctl --user start ${_service_name}.service'",
          user    => $_user,
          cwd     => $_safe_cwd,
          onlyif  => $_bus_check,
          unless  => "${_scu} /usr/bin/systemctl --user is-active ${_service_name}.service'",
          require => [Exec["systemd-user-enable-${name}"]] + $_runtime_files,
        }
      }

      # Rolling-update trigger (refreshonly — only fires on compose/env file change).
      # Calls `podman-compose up -d` directly instead of `systemctl restart`,
      # so compose recreates only services whose image/config actually changed
      # — other services keep running.
      exec { "podman-compose-restart-${name}":
        command     => "${_scu} ${_recreate_ops}'",
        cwd         => $_compose_dir,
        user        => $_user,
        onlyif      => $_bus_check,
        refreshonly => true,
        require     => Exec["systemd-user-enable-${name}"],
      }
    } else {
      # ── Rootful: system-level systemd unit ──

      file { "/etc/systemd/system/${_service_name}.service":
        ensure  => file,
        owner   => 'root',
        group   => 'root',
        mode    => '0644',
        content => epp('podman_compose/systemd_system_unit.epp', {
          'project_name'         => $name,
          'compose_dir'          => $_compose_dir,
          'compose_binary'       => $podman_compose::compose_binary,
          'compose_file_name'    => $compose_file_name,
          'pull_on_start'        => $pull_on_start,
          'service_timeout'      => $service_timeout,
          'extra_systemd_config' => $extra_systemd_config,
        }),
        notify  => Exec["systemctl-daemon-reload-${name}"],
      }

      exec { "systemctl-daemon-reload-${name}":
        command     => '/usr/bin/systemctl daemon-reload',
        refreshonly => true,
      }

      $_service_ensure = $ensure ? {
        'running' => 'running',
        'stopped' => 'stopped',
      }

      service { $_service_name:
        ensure    => $_service_ensure,
        enable    => true,
        require   => [
          File["/etc/systemd/system/${_service_name}.service"],
          File["${_compose_dir}/${compose_file_name}"],
          Exec["systemctl-daemon-reload-${name}"],
        ],
        subscribe => File["${_compose_dir}/${compose_file_name}"],
      }

      # Rolling-update trigger (refreshonly — only fires on compose/env file change).
      # Calls compose directly instead of `systemctl restart`, so only the
      # services whose image/config changed get recreated.
      # Wrapped in `bash -c` so the 'down-up' strategy's `&&` is interpreted by
      # a shell (Puppet's exec doesn't run through one by default).
      exec { "podman-compose-restart-${name}":
        command     => "/usr/bin/bash -c '${_recreate_ops}'",
        cwd         => $_compose_dir,
        path        => ['/usr/local/bin', '/usr/bin', '/bin'],
        refreshonly => true,
        require     => Service[$_service_name],
      }
    }

    # ---------------------------------------------------------------
    # Drift detection: verify each service's running image digest
    # matches the desired image (after a quiet `pull`). If any service
    # has drifted (image updated in registry, manual change, missing
    # container, …) trigger a rolling `up -d` so only affected services
    # are recreated.
    # ---------------------------------------------------------------
    if $verify_running_image and $ensure == 'running' {
      # Service → image map, written as a tab-separated file so the verify
      # script doesn't need a YAML parser. Only services with an `image:` key
      # are checked (services built from local Dockerfiles have no static
      # image reference and are skipped).
      $_service_images = $compose['services'].reduce({}) |Hash $memo, $entry| {
        $_img = $entry[1]['image']
        $_img ? {
          undef   => $memo,
          default => $memo + { $entry[0] => $_img },
        }
      }

      if ! empty($_service_images) {
        $_images_content = $_service_images.reduce('') |String $acc, $entry| {
          "${acc}${entry[0]}\t${entry[1]}\n"
        }

        file { "${_compose_dir}/.puppet-images.txt":
          ensure  => file,
          owner   => $_user,
          group   => $_group,
          mode    => '0640',
          content => $_images_content,
        }

        file { "${_compose_dir}/.puppet-verify-images.sh":
          ensure  => file,
          owner   => $_user,
          group   => $_group,
          mode    => '0750',
          content => epp('podman_compose/verify_images.sh.epp', {
            'compose_binary'    => $podman_compose::compose_binary,
            'compose_file_name' => $compose_file_name,
          }),
        }

        if $rootless {
          exec { "podman-compose-verify-${name}":
            command => "${_scu} ${_compose_dir}/.puppet-verify-images.sh update'",
            unless  => "${_scu} ${_compose_dir}/.puppet-verify-images.sh check'",
            cwd     => $_compose_dir,
            user    => $_user,
            onlyif  => $_bus_check,
            require => [
              File["${_compose_dir}/.puppet-images.txt"],
              File["${_compose_dir}/.puppet-verify-images.sh"],
              File["${_compose_dir}/${compose_file_name}"],
              Exec["systemd-user-start-${name}"],
            ],
          }
        } else {
          exec { "podman-compose-verify-${name}":
            command => "${_compose_dir}/.puppet-verify-images.sh update",
            unless  => "${_compose_dir}/.puppet-verify-images.sh check",
            cwd     => $_compose_dir,
            path    => ['/usr/local/bin', '/usr/bin', '/bin'],
            require => [
              File["${_compose_dir}/.puppet-images.txt"],
              File["${_compose_dir}/.puppet-verify-images.sh"],
              Service[$_service_name],
            ],
          }
        }
      }
    }
  }
}
