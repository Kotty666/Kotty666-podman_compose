# @summary Manage a system user for rootless podman-compose
#
# Creates the user, enables loginctl linger (so user services
# persist after logout), and ensures required directories exist.
#
# @param user
#   Username to manage. Defaults to the resource title.
# @param home
#   Home directory path.
# @param shell
#   Login shell.
# @param system_user
#   Create as system user.
# @param manage_home
#   Let Puppet manage the home directory.
#
define podman_compose::user (
  String[1]            $user        = $name,
  Stdlib::Absolutepath $home        = "/home/${name}",
  Stdlib::Absolutepath $shell       = '/bin/bash',
  Boolean              $system_user = true,
  Boolean              $manage_home = true,
) {
  # Avoid duplicate user resources
  if ! defined(User[$user]) {
    user { $user:
      ensure     => present,
      home       => $home,
      shell      => $shell,
      system     => $system_user,
      managehome => $manage_home,
    }
  }

  # Enable lingering so user services survive logout
  exec { "loginctl-enable-linger-${user}":
    command => "/usr/bin/loginctl enable-linger ${user}",
    unless  => "/usr/bin/test -f /var/lib/systemd/linger/${user}",
    require => User[$user],
  }

  # `enable-linger` alone does not always cause systemd-logind to spawn the
  # user manager fast enough — on fresh installs /run/user/<uid>/bus may
  # still be missing when later rootless `systemctl --user` calls run,
  # producing "Failed to connect to bus: No such file or directory".
  # Trigger the user manager explicitly so the bus socket is created
  # before any dependent exec fires.
  exec { "start-user-manager-${user}":
    command => "/usr/bin/bash -c 'systemctl start user@\$(id -u ${user}).service'",
    unless  => "/usr/bin/bash -c 'test -S /run/user/\$(id -u ${user})/bus'",
    require => Exec["loginctl-enable-linger-${user}"],
  }

  # Ensure XDG_RUNTIME_DIR will be available at next login
  # (systemd-logind creates it, but we verify the linger file)
}
