# @summary Manage a scheduled podman-compose job via systemd timer
#
# Renders a compose file, creates a oneshot systemd service and a
# timer unit. The timer fires on the configured schedule, starts the
# compose stack, waits for completion, then tears it down.
#
# Two run modes are supported:
# - **full stack** (default): `podman-compose up --abort-on-container-exit`
#   followed by `podman-compose down`. Useful when the job needs
#   sidecars (database, queue, etc.).
# - **single service** (`run_service`): `podman-compose run --rm <svc>`.
#   Lighter weight, ideal when only one container does the work.
#
# @param compose
#   Compose file content as a Hash. Must contain 'services'.
# @param on_calendar
#   Systemd OnCalendar expression (see `man systemd.time`).
#   Examples: 'daily', 'weekly', '*-*-* 02:00:00', 'Mon *-*-* 06:30:00'
# @param ensure
#   'present' or 'absent'.
# @param rootless
#   Run as unprivileged user.
# @param user
#   System user (required when rootless).
# @param group
#   Primary group. Defaults to $user.
# @param manage_user
#   Whether to manage the system user resource.
# @param compose_dir
#   Project directory. Auto-derived if unset.
# @param env_vars
#   KEY=VALUE pairs for .env file.
# @param env_secrets
#   Sensitive KEY=VALUE pairs merged into .env (eyaml-friendly).
# @param run_service
#   If set, use `podman-compose run --rm <run_service>` instead of
#   bringing up the full stack. Name must match a service in compose.
# @param pull_before_run
#   Pull images before each run.
# @param on_boot_sec
#   Optional OnBootSec for timer (e.g. '5min'). Runs once after boot.
# @param persistent
#   Catch up missed runs if the machine was off. Default: true.
# @param randomized_delay_sec
#   Jitter window to spread load (e.g. '15min').
# @param accuracy_sec
#   Timer coalescing accuracy (e.g. '1s' for precise, '1min' default).
# @param compose_file_name
#   Name of the compose file. Default: compose.yml (the modern Compose Spec
#   name). Set to 'docker-compose.yml' for the legacy filename.
# @param service_timeout
#   TimeoutStartSec for the oneshot service.
# @param extra_systemd_config
#   Additional [Service] directives.
# @param registries
#   Hash of registry server => {username, password} for `podman login`.
#   Same semantics as podman_compose::project's `registries`: credentials
#   are piped via stdin and tracked via SHA256 sentinel for change
#   detection.
#
# @example Daily backup at 2 AM
#   podman_compose::cron_projects:
#     backup:
#       user: backup
#       rootless: true
#       on_calendar: '*-*-* 02:00:00'
#       randomized_delay_sec: '15min'
#       run_service: restic
#       compose:
#         services:
#           restic:
#             image: "restic/restic:0.17"
#             volumes:
#               - "/data:/data:ro"
#               - "./cache:/var/cache/restic"
#             env_file:
#               - .env
#             command: ["backup", "/data", "--verbose"]
#
# @example Hourly cleanup with sidecars
#   podman_compose::cron_projects:
#     cleanup:
#       rootless: false
#       on_calendar: 'hourly'
#       persistent: false
#       compose:
#         services:
#           worker:
#             image: "myorg/cleanup:latest"
#             depends_on:
#               - redis
#           redis:
#             image: "redis:7-alpine"
#
define podman_compose::cron (
  Hash                                $compose,
  String[1]                           $on_calendar,
  Enum['present', 'absent']           $ensure                = 'present',
  Boolean                             $rootless              = true,
  Optional[String[1]]                 $user                  = undef,
  Optional[String[1]]                 $group                 = undef,
  Boolean                             $manage_user           = true,
  Optional[Stdlib::Absolutepath]      $compose_dir           = undef,
  Hash[String[1], String]             $env_vars              = {},
  Hash[String[1], Sensitive[String]]  $env_secrets           = {},
  Optional[String[1]]                 $run_service           = undef,
  Boolean                             $pull_before_run       = true,
  Optional[String[1]]                 $on_boot_sec           = undef,
  Boolean                             $persistent            = true,
  Optional[String[1]]                 $randomized_delay_sec  = undef,
  Optional[String[1]]                 $accuracy_sec          = undef,
  String[1]                           $compose_file_name     = 'compose.yml',
  Integer[60]                         $service_timeout       = 600,
  Hash[String, String]                $extra_systemd_config  = {},
  Podman_compose::Registries          $registries            = {},
) {
  require podman_compose::install

  # --- Validation ---

  if $rootless and $user == undef {
    fail("podman_compose::cron[${name}]: 'user' is required when rootless is true")
  }

  unless 'services' in $compose {
    fail("podman_compose::cron[${name}]: 'compose' hash must contain a 'services' key")
  }

  if $run_service and !($run_service in $compose['services']) {
    fail("podman_compose::cron[${name}]: run_service '${run_service}' not found in compose services")
  }

  # --- Defaults ---

  $_user  = $rootless ? { true => $user, default => 'root' }
  $_group = pick($group, $_user)

  $_compose_dir = $compose_dir ? {
    undef   => $rootless ? {
      true  => "/home/${_user}/${podman_compose::user_compose_dir_name}/${name}",
      false => "${podman_compose::root_compose_dir}/${name}",
    },
    default => $compose_dir,
  }

  $_service_name = "podman-compose-cron-${name}"
  $_timer_name   = "${_service_name}.timer"

  # Shell wrapper for rootless systemctl.
  # On a fresh install `loginctl enable-linger` starts the user manager
  # asynchronously, so /run/user/<uid>/bus may not exist yet when this
  # exec runs. Wait up to ~30s for the bus socket to appear — no-op
  # once it's ready.
  $_scu = '/usr/bin/bash -c \'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus && for _i in $(seq 1 30); do test -S "$XDG_RUNTIME_DIR/bus" && break; sleep 1; done &&'

  # Guard for rootless `--user` exec calls. If /run/user/<uid>/bus isn't
  # ready yet (very fresh install: linger was just enabled, user manager
  # still spinning up), skip the exec gracefully — Puppet succeeds, and
  # the next run picks it up once the bus is there.
  $_bus_check = "/usr/bin/bash -c 'test -S /run/user/\$(id -u ${_user})/bus'"

  # Safe cwd for non-root execs (Puppet agent's cwd is usually /root,
  # which a non-root user can't enter → "cannot chdir to /root: Permission denied").
  $_safe_cwd = '/tmp'

  # ==========================================================
  # ensure => absent
  # ==========================================================

  if $ensure == 'absent' {
    if $rootless {
      $_absent_unit_dir = "/home/${_user}/.config/systemd/user"

      exec { "cron-stop-timer-${name}":
        command => "${_scu} /usr/bin/systemctl --user stop ${_timer_name} || true'",
        user    => $_user,
        cwd     => $_safe_cwd,
        onlyif  => [
          $_bus_check,
          "${_scu} /usr/bin/systemctl --user is-active ${_timer_name}'",
        ],
      }

      file { "${_absent_unit_dir}/${_service_name}.service":
        ensure  => absent,
        require => Exec["cron-stop-timer-${name}"],
      }
      file { "${_absent_unit_dir}/${_timer_name}":
        ensure  => absent,
        require => Exec["cron-stop-timer-${name}"],
      }
    } else {
      service { $_timer_name:
        ensure => stopped,
        enable => false,
      }

      file { "/etc/systemd/system/${_service_name}.service":
        ensure  => absent,
        require => Service[$_timer_name],
        notify  => Exec["cron-daemon-reload-${name}"],
      }
      file { "/etc/systemd/system/${_timer_name}":
        ensure  => absent,
        require => Service[$_timer_name],
        notify  => Exec["cron-daemon-reload-${name}"],
      }

      exec { "cron-daemon-reload-${name}":
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
    # ==========================================================
    # ensure => present
    # ==========================================================

    $_parent_dir = dirname($_compose_dir)

    # --- User (rootless) ---

    # ensure_resource so the same user can be shared across multiple
    # cron jobs and/or projects without a duplicate declaration error.
    # Ordering is expressed via a chaining arrow (which may appear more
    # than once) rather than a `before` param, so resources sharing the
    # user but with different parent dirs don't clash on ensure_resource's
    # parameter comparison.
    if $rootless and $manage_user {
      ensure_resource('podman_compose::user', $_user)
      Podman_compose::User[$_user] -> File[$_parent_dir]
    }

    # --- Registry logins ---

    # ensure_resource avoids duplicates when multiple cron jobs/projects
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
    # projects share the same parent.
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
    }

    # --- .env ---

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
      }
    }

    # --- Systemd units ---

    $_unit_tpl_params = {
      'project_name'         => $name,
      'compose_dir'          => $_compose_dir,
      'compose_binary'       => $podman_compose::compose_binary,
      'compose_file_name'    => $compose_file_name,
      'pull_before_run'      => $pull_before_run,
      'service_timeout'      => $service_timeout,
      'extra_systemd_config' => $extra_systemd_config,
      'run_service'          => $run_service,
    }

    $_timer_tpl_params = {
      'project_name'          => $name,
      'service_name'          => $_service_name,
      'on_calendar'           => $on_calendar,
      'on_boot_sec'           => $on_boot_sec,
      'persistent'            => $persistent,
      'randomized_delay_sec'  => $randomized_delay_sec,
      'accuracy_sec'          => $accuracy_sec,
    }

    if $rootless {
      $_user_unit_dir = "/home/${_user}/.config/systemd/user"

      exec { "cron-mkdir-systemd-user-${name}":
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
        content => epp('podman_compose/systemd_cron_user_unit.epp', $_unit_tpl_params),
        notify  => Exec["cron-user-reload-${name}"],
        require => Exec["cron-mkdir-systemd-user-${name}"],
      }

      file { "${_user_unit_dir}/${_timer_name}":
        ensure  => file,
        owner   => $_user,
        group   => $_group,
        mode    => '0644',
        content => epp('podman_compose/systemd_timer.epp', $_timer_tpl_params),
        notify  => Exec["cron-user-reload-${name}"],
        require => Exec["cron-mkdir-systemd-user-${name}"],
      }

      exec { "cron-user-reload-${name}":
        command     => "${_scu} /usr/bin/systemctl --user daemon-reload'",
        user        => $_user,
        cwd         => $_safe_cwd,
        onlyif      => $_bus_check,
        refreshonly => true,
      }

      exec { "cron-user-enable-timer-${name}":
        command => "${_scu} /usr/bin/systemctl --user enable --now ${_timer_name}'",
        user    => $_user,
        cwd     => $_safe_cwd,
        onlyif  => $_bus_check,
        unless  => "${_scu} /usr/bin/systemctl --user is-enabled ${_timer_name}'",
        require => [
          File["${_user_unit_dir}/${_timer_name}"],
          File["${_user_unit_dir}/${_service_name}.service"],
          Exec["cron-user-reload-${name}"],
        ],
      }
    } else {
      # Rootful

      file { "/etc/systemd/system/${_service_name}.service":
        ensure  => file,
        owner   => 'root',
        group   => 'root',
        mode    => '0644',
        content => epp('podman_compose/systemd_cron_unit.epp', $_unit_tpl_params),
        notify  => Exec["cron-daemon-reload-${name}"],
      }

      file { "/etc/systemd/system/${_timer_name}":
        ensure  => file,
        owner   => 'root',
        group   => 'root',
        mode    => '0644',
        content => epp('podman_compose/systemd_timer.epp', $_timer_tpl_params),
        notify  => Exec["cron-daemon-reload-${name}"],
      }

      exec { "cron-daemon-reload-${name}":
        command     => '/usr/bin/systemctl daemon-reload',
        refreshonly => true,
      }

      service { $_timer_name:
        ensure  => running,
        enable  => true,
        require => [
          File["/etc/systemd/system/${_timer_name}"],
          File["/etc/systemd/system/${_service_name}.service"],
          Exec["cron-daemon-reload-${name}"],
        ],
      }
    }
  }
}
