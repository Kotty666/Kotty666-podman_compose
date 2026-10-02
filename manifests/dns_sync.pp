# @summary Push host nameserver changes into running podman-compose containers
#
# In environments where DNS servers change (re-deployed resolvers with new
# IPs), long-running containers keep the nameservers they saw at creation
# time and eventually lose DNS. This class installs a small oneshot service
# that is triggered by a systemd path unit whenever the host resolv.conf
# changes (plus a timer as fallback) and updates every running container of
# the projects that opted in - without restarting them:
#
# * Containers with a copy of the host resolv.conf get that copy rewritten
#   in place (the bind mount makes the change visible immediately).
# * Containers on DNS-enabled networks (aardvark-dns) are served via the
#   network gateway; aardvark-dns is told to reload its upstream servers
#   (SIGHUP on >= 1.12, process restart on older releases; >= 1.17 also
#   watches resolv.conf itself). For rootless users the resolv.conf copy
#   inside the rootless network namespace is refreshed first.
#
# Nameservers not inherited from the host (explicit `dns:` in compose,
# network gateways, pasta/slirp4netns forwarders) are never changed.
#
# @api private
#
class podman_compose::dns_sync {
  assert_private()

  $_ensure      = $podman_compose::dns_sync
  $_conf_dir    = '/etc/podman-compose/dns-sync.d'
  $_script_path = '/usr/local/libexec/podman-dns-sync.py'
  $_state_file  = '/var/lib/podman-dns-sync/state.json'
  $_unit_dir    = '/etc/systemd/system'

  $_file_ensure = $_ensure ? { true => 'file', default => 'absent' }

  # Marker files are written by podman_compose::project; purge removes those
  # of projects that were dropped from Hiera.
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
    content => epp('podman_compose/dns_sync.py.epp', {
      'conf_dir'         => $_conf_dir,
      'state_file'       => $_state_file,
      'restart_aardvark' => $podman_compose::dns_sync_restart_aardvark,
    }),
  }

  file { "${_unit_dir}/podman-dns-sync.service":
    ensure  => $_file_ensure,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('podman_compose/systemd_dns_sync_unit.epp', {
      'script_path' => $_script_path,
    }),
    notify  => Exec['podman-dns-sync-daemon-reload'],
  }

  file { "${_unit_dir}/podman-dns-sync.path":
    ensure  => $_file_ensure,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('podman_compose/systemd_dns_sync_path.epp', {
      'watch_paths' => $podman_compose::dns_sync_watch_paths,
    }),
    notify  => Exec['podman-dns-sync-daemon-reload'],
  }

  file { "${_unit_dir}/podman-dns-sync.timer":
    ensure  => $_file_ensure,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('podman_compose/systemd_dns_sync_timer.epp', {
      'interval' => $podman_compose::dns_sync_interval,
    }),
    notify  => Exec['podman-dns-sync-daemon-reload'],
  }

  exec { 'podman-dns-sync-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
  }

  if $_ensure {
    service { ['podman-dns-sync.path', 'podman-dns-sync.timer']:
      ensure    => running,
      enable    => true,
      require   => [
        File[$_script_path],
        File["${_unit_dir}/podman-dns-sync.service"],
        Exec['podman-dns-sync-daemon-reload'],
      ],
      subscribe => [
        File["${_unit_dir}/podman-dns-sync.path"],
        File["${_unit_dir}/podman-dns-sync.timer"],
      ],
    }
  } else {
    # Stop before the unit files disappear, so systemd still knows them.
    service { ['podman-dns-sync.path', 'podman-dns-sync.timer']:
      ensure => stopped,
      enable => false,
      before => [
        File["${_unit_dir}/podman-dns-sync.path"],
        File["${_unit_dir}/podman-dns-sync.timer"],
        File["${_unit_dir}/podman-dns-sync.service"],
      ],
    }

    file { dirname($_state_file):
      ensure  => absent,
      recurse => true,
      force   => true,
    }
  }
}
