# @summary Install podman and podman-compose
#
# @api private
#
class podman_compose::install {
  assert_private()

  if $podman_compose::manage_package {
    package { $podman_compose::podman_package:
      ensure => installed,
    }
  }

  if $podman_compose::manage_systemd_container {
    ensure_packages([$podman_compose::systemd_container_package], { 'ensure' => 'installed' })
  }

  # Only require the podman package resource when we actually manage it.
  # Otherwise (`manage_package => false`) the user is expected to install
  # podman out-of-band and we must not reference a non-existent resource.
  $_podman_pkg_require = $podman_compose::manage_package ? {
    true    => [Package[$podman_compose::podman_package]],
    default => [],
  }

  case $podman_compose::compose_install_method {
    'package': {
      package { $podman_compose::compose_package:
        ensure  => $podman_compose::compose_ensure,
        require => $_podman_pkg_require,
      }
    }
    'pip': {
      # Ensure pip is available
      $_pip_package = $facts['os']['family'] ? {
        'Debian' => 'python3-pip',
        'RedHat' => 'python3-pip',
        default  => 'python3-pip',
      }

      ensure_packages([$_pip_package], { 'ensure' => 'installed' })

      exec { 'pip-install-podman-compose':
        command => "/usr/bin/pip3 install --break-system-packages ${podman_compose::compose_pip_package}",
        creates => $podman_compose::compose_binary,
        require => $_podman_pkg_require + [Package[$_pip_package]],
      }
    }
    default: {
      fail("Unsupported install method: ${podman_compose::compose_install_method}")
    }
  }
}
