# @summary Periodically remove old podman images of podman-compose projects
#
# Installs a oneshot service plus timer that cleans up the image store of
# root and of every rootless user hosting a podman-compose project or cron
# job (each rootless user has its own store). Which stores are cleaned and
# which images are referenced by managed compose files is taken from marker
# files written by podman_compose::project and podman_compose::cron.
#
# * `image_prune_keep` unset: only orphaned images (no tag, not used by a
#   container) are removed - the equivalent of `podman image prune`.
# * `image_prune_keep` = N: per repository the N newest images are kept as
#   rollback candidates, all older ones are removed.
#
# Images used by a container or referenced by a managed compose file are
# never removed.
#
# @api private
#
class podman_compose::image_prune {
  assert_private()

  $_ensure      = $podman_compose::image_prune
  $_conf_dir    = '/etc/podman-compose/image-prune.d'
  $_script_path = '/usr/local/libexec/podman-image-prune.py'
  $_unit_dir    = '/etc/systemd/system'

  $_file_ensure = $_ensure ? { true => 'file', default => 'absent' }

  # Marker files are written by podman_compose::project and ::cron; purge
  # removes those of projects that were dropped from Hiera.
  ensure_resource('file', ['/etc/podman-compose', '/usr/local/libexec'], {
    ensure => directory,
  })

  file { $_conf_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    recurse => true,
    purge   => true,
  }

  file { $_script_path:
    ensure  => $_file_ensure,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    content => epp('podman_compose/image_prune.py.epp', {
      'conf_dir' => $_conf_dir,
      'keep'     => $podman_compose::image_prune_keep,
      'dry_run'  => $podman_compose::image_prune_dry_run,
    }),
  }

  file { "${_unit_dir}/podman-image-prune.service":
    ensure  => $_file_ensure,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('podman_compose/systemd_image_prune_unit.epp', {
      'script_path' => $_script_path,
    }),
    notify  => Exec['podman-image-prune-daemon-reload'],
  }

  file { "${_unit_dir}/podman-image-prune.timer":
    ensure  => $_file_ensure,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('podman_compose/systemd_image_prune_timer.epp', {
      'on_calendar'          => $podman_compose::image_prune_on_calendar,
      'randomized_delay_sec' => $podman_compose::image_prune_randomized_delay_sec,
    }),
    notify  => Exec['podman-image-prune-daemon-reload'],
  }

  exec { 'podman-image-prune-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
  }

  if $_ensure {
    service { 'podman-image-prune.timer':
      ensure    => running,
      enable    => true,
      require   => [
        File[$_script_path],
        File["${_unit_dir}/podman-image-prune.service"],
        Exec['podman-image-prune-daemon-reload'],
      ],
      subscribe => File["${_unit_dir}/podman-image-prune.timer"],
    }
  } else {
    # Stop before the unit files disappear, so systemd still knows them.
    service { 'podman-image-prune.timer':
      ensure => stopped,
      enable => false,
      before => [
        File["${_unit_dir}/podman-image-prune.timer"],
        File["${_unit_dir}/podman-image-prune.service"],
      ],
    }
  }
}
