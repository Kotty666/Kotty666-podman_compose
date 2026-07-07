# @summary CPU-based horizontal autoscaler for a single compose service
#
# Deploys a small long-running Python daemon (a systemd service with
# `Restart=always`) that periodically samples the average CPU usage across all
# running replicas of one compose service and scales it up or down between
# `min_replicas` and `max_replicas` via
# `podman-compose up -d --no-recreate --scale <service>=<n>`.
#
# This operates on a project already managed by `podman_compose::project`; it
# does NOT render a compose file of its own. To avoid Puppet and the autoscaler
# fighting over the replica count, the referenced project MUST:
#   * NOT set a static `scale` for this service, and
#   * set `verify_running_image => false` (or otherwise not force-recreate the
#     service on every run) — the drift-verify recreate would otherwise reset
#     the replica count on the next Puppet run.
# The scaled service must also not set a fixed `container_name:` and must not
# statically publish a colliding host port (see `podman_compose::project`'s
# `scale` docs). Only stateless services should be autoscaled.
#
# @param service
#   Name of the compose service to scale. Must match a service in the project's
#   compose file.
# @param project
#   Name of the `podman_compose::project` (its title). Used to derive the
#   compose directory and, by default, the Compose project name. Defaults to
#   this resource's title.
# @param ensure
#   'present' deploys the autoscaler, 'absent' stops and removes it.
# @param rootless
#   Run the daemon as an unprivileged user (systemd user unit) or as root.
# @param user
#   System user owning the project. Required when rootless is true.
# @param group
#   Primary group for the user. Defaults to $user.
# @param manage_user
#   Whether to declare the system user resource. Defaults to false: the
#   autoscaler is an add-on to an existing `podman_compose::project`, which
#   already owns the user (with its subuid/subgid ranges). Only set true for a
#   standalone deployment where no project declares the user — in that case the
#   user's subid ranges must be managed elsewhere (podman_compose::user default
#   `manage_subid` requires them).
# @param compose_dir
#   Absolute path to the project directory. Auto-derived from `project` if unset
#   (mirrors `podman_compose::project`).
# @param compose_file_name
#   Name of the compose file. Default: compose.yml.
# @param compose_project
#   Override the Compose project name used to match containers by label. When
#   unset the daemon derives it from the compose directory basename (lowercased),
#   matching Compose's default.
# @param min_replicas
#   Lower bound on replica count. The daemon never scales below this.
# @param max_replicas
#   Upper bound on replica count. The daemon never scales above this.
# @param cpu_high
#   Average CPU percent (summed per container, as podman reports it) above which
#   the service scales out by `step`.
# @param cpu_low
#   Average CPU percent below which the service scales in by `step`. Must be
#   lower than `cpu_high` to leave a stable band and avoid flapping.
# @param step
#   How many replicas to add/remove per scaling action.
# @param interval
#   Seconds between CPU samples.
# @param cooldown
#   Minimum seconds between two scaling actions, so a burst doesn't ratchet the
#   count up and down repeatedly.
# @param proxy_env
#   HTTP(S) proxy environment variables set on the daemon's unit so the
#   `up -d` (which may pull) can reach the registry through a forward proxy.
#
# @example Autoscale the 'api' service of the 'api' project between 2 and 6
#   podman_compose::autoscale { 'api':
#     service      => 'api',
#     user         => 'api',
#     min_replicas => 2,
#     max_replicas => 6,
#     cpu_high     => 70,
#     cpu_low      => 30,
#     interval     => 30,
#     cooldown     => 120,
#   }
#
define podman_compose::autoscale (
  String[1]                           $service,
  String[1]                           $project              = $name,
  Enum['present', 'absent']           $ensure               = 'present',
  Boolean                             $rootless             = true,
  Optional[String[1]]                 $user                 = undef,
  Optional[String[1]]                 $group                = undef,
  Boolean                             $manage_user          = false,
  Optional[Stdlib::Absolutepath]      $compose_dir          = undef,
  String[1]                           $compose_file_name    = 'compose.yml',
  Optional[String[1]]                 $compose_project      = undef,
  Integer[1]                          $min_replicas         = 1,
  Integer[1]                          $max_replicas         = 5,
  Integer[1, 100]                     $cpu_high             = 70,
  Integer[0, 100]                     $cpu_low              = 30,
  Integer[1]                          $step                 = 1,
  Integer[1]                          $interval             = 30,
  Integer[0]                          $cooldown             = 120,
  Hash[String[1], String[1]]          $proxy_env            = {},
) {
  require podman_compose::install

  # --- Validation ---

  if $rootless and $user == undef {
    fail("podman_compose::autoscale[${name}]: 'user' is required when rootless is true")
  }

  if $min_replicas > $max_replicas {
    fail("podman_compose::autoscale[${name}]: min_replicas (${min_replicas}) must be <= max_replicas (${max_replicas})")
  }

  if $cpu_low >= $cpu_high {
    fail("podman_compose::autoscale[${name}]: cpu_low (${cpu_low}) must be < cpu_high (${cpu_high}) to leave a stable band")
  }

  # --- Defaults ---

  $_user  = $rootless ? { true => $user, default => 'root' }
  $_group = pick($group, $_user)

  $_compose_dir = $compose_dir ? {
    undef   => $rootless ? {
      true  => "/home/${_user}/${podman_compose::user_compose_dir_name}/${project}",
      false => "${podman_compose::root_compose_dir}/${project}",
    },
    default => $compose_dir,
  }

  $_service_name = "podman-compose-autoscale-${name}"
  $_script_path  = "${_compose_dir}/.puppet-autoscale-${service}.py"

  # Shell wrapper for rootless systemctl. On a fresh install linger was just
  # enabled and the user manager may still be spinning up, so wait for the bus.
  $_scu = '/usr/bin/bash -c \'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus && for _i in $(seq 1 30); do test -S "$XDG_RUNTIME_DIR/bus" && break; sleep 1; done &&'

  # Guard: skip rootless `--user` execs gracefully until the bus socket exists.
  $_bus_check = "/usr/bin/bash -c 'test -S /run/user/\$(id -u ${_user})/bus'"

  # Safe cwd for non-root execs (Puppet agent cwd is usually /root).
  $_safe_cwd = '/tmp'

  if $ensure == 'absent' {
    if $rootless {
      $_absent_unit_dir = "/home/${_user}/.config/systemd/user"

      exec { "autoscale-stop-${name}":
        command => "${_scu} /usr/bin/systemctl --user disable --now ${_service_name}.service || true'",
        user    => $_user,
        cwd     => $_safe_cwd,
        onlyif  => [
          $_bus_check,
          "${_scu} /usr/bin/systemctl --user is-active ${_service_name}.service'",
        ],
      }

      file { "${_absent_unit_dir}/${_service_name}.service":
        ensure  => absent,
        require => Exec["autoscale-stop-${name}"],
      }
    } else {
      service { $_service_name:
        ensure => stopped,
        enable => false,
      }

      file { "/etc/systemd/system/${_service_name}.service":
        ensure  => absent,
        require => Service[$_service_name],
        notify  => Exec["autoscale-daemon-reload-${name}"],
      }

      exec { "autoscale-daemon-reload-${name}":
        command     => '/usr/bin/systemctl daemon-reload',
        refreshonly => true,
      }
    }

    file { $_script_path:
      ensure => absent,
    }
  } else {
    # =========================================================
    # ensure => present
    # =========================================================

    # Share the user resource with the project/cron declarations.
    if $rootless and $manage_user {
      ensure_resource('podman_compose::user', $_user)
    }

    # --- Autoscaler script ---

    file { $_script_path:
      ensure  => file,
      owner   => $_user,
      group   => $_group,
      mode    => '0750',
      content => epp('podman_compose/autoscale.py.epp', {
        'compose_binary'    => $podman_compose::compose_binary,
        'compose_file_name' => $compose_file_name,
        'compose_dir'       => $_compose_dir,
        'compose_project'   => pick_default($compose_project, ''),
        'service'           => $service,
        'min_replicas'      => $min_replicas,
        'max_replicas'      => $max_replicas,
        'cpu_high'          => $cpu_high,
        'cpu_low'           => $cpu_low,
        'step'              => $step,
        'interval'          => $interval,
        'cooldown'          => $cooldown,
      }),
    }

    # --- Systemd unit ---

    $_unit_tpl_params = {
      'name'         => $name,
      'project'      => $project,
      'service'      => $service,
      'compose_dir'  => $_compose_dir,
      'script_path'  => $_script_path,
      'interval'     => $interval,
      'proxy_env'    => $proxy_env,
    }

    if $rootless {
      $_user_unit_dir = "/home/${_user}/.config/systemd/user"

      exec { "autoscale-mkdir-systemd-user-${name}":
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
        content => epp('podman_compose/systemd_autoscale_user_unit.epp', $_unit_tpl_params),
        notify  => Exec["autoscale-user-reload-${name}"],
        require => Exec["autoscale-mkdir-systemd-user-${name}"],
      }

      exec { "autoscale-user-reload-${name}":
        command     => "${_scu} /usr/bin/systemctl --user daemon-reload'",
        user        => $_user,
        cwd         => $_safe_cwd,
        onlyif      => $_bus_check,
        refreshonly => true,
      }

      # Enable + (re)start so the daemon picks up config changes. A changed
      # script/unit notifies a restart; enable is idempotent via `unless`.
      exec { "autoscale-user-enable-${name}":
        command => "${_scu} /usr/bin/systemctl --user enable --now ${_service_name}.service'",
        user    => $_user,
        cwd     => $_safe_cwd,
        onlyif  => $_bus_check,
        unless  => "${_scu} /usr/bin/systemctl --user is-enabled ${_service_name}.service'",
        require => [
          File["${_user_unit_dir}/${_service_name}.service"],
          File[$_script_path],
          Exec["autoscale-user-reload-${name}"],
        ],
      }

      exec { "autoscale-user-restart-${name}":
        command     => "${_scu} /usr/bin/systemctl --user restart ${_service_name}.service'",
        user        => $_user,
        cwd         => $_safe_cwd,
        onlyif      => $_bus_check,
        refreshonly => true,
        require     => Exec["autoscale-user-enable-${name}"],
        subscribe   => [
          File["${_user_unit_dir}/${_service_name}.service"],
          File[$_script_path],
        ],
      }
    } else {
      file { "/etc/systemd/system/${_service_name}.service":
        ensure  => file,
        owner   => 'root',
        group   => 'root',
        mode    => '0644',
        content => epp('podman_compose/systemd_autoscale_unit.epp', $_unit_tpl_params),
        notify  => Exec["autoscale-daemon-reload-${name}"],
      }

      exec { "autoscale-daemon-reload-${name}":
        command     => '/usr/bin/systemctl daemon-reload',
        refreshonly => true,
      }

      service { $_service_name:
        ensure    => running,
        enable    => true,
        require   => [
          File["/etc/systemd/system/${_service_name}.service"],
          File[$_script_path],
          Exec["autoscale-daemon-reload-${name}"],
        ],
        subscribe => [
          File["/etc/systemd/system/${_service_name}.service"],
          File[$_script_path],
        ],
      }
    }
  }
}
