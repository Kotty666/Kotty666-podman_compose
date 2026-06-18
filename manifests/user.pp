# @summary Manage a system user for rootless podman-compose
#
# Creates the user, enables loginctl linger (so user services
# persist after logout), ensures required directories exist, and
# configures /etc/subuid and /etc/subgid for rootless user namespaces.
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
# @param manage_subid
#   Whether to manage /etc/subuid and /etc/subgid entries.
# @param subuid_start
#   Start of the subordinate UID range allocated to this user.
#   Each user on a host must get a non-overlapping range.
#   Common convention: first user 100000, second 165536, third 231072, …
# @param subuid_count
#   Number of subordinate UIDs allocated to this user (default 65536).
# @param subgid_start
#   Start of the subordinate GID range allocated to this user.
#   Must not overlap with any other user's range on the same host.
# @param subgid_count
#   Number of subordinate GIDs allocated to this user (default 65536).
#
define podman_compose::user (
  String[1]            $user         = $name,
  Stdlib::Absolutepath $home         = "/home/${name}",
  Stdlib::Absolutepath $shell        = '/bin/bash',
  Boolean              $system_user  = true,
  Boolean              $manage_home  = true,
  Boolean              $manage_subid = true,
  Optional[Integer]    $subuid_start = undef,
  Integer              $subuid_count = 65536,
  Optional[Integer]    $subgid_start = undef,
  Integer              $subgid_count = 65536,
) {
  if $manage_subid and ($subuid_start == undef or $subgid_start == undef) {
    fail("podman_compose::user[${name}]: subuid_start and subgid_start must be set when manage_subid is true. Each user on a host needs a unique non-overlapping range (e.g. first user: 100000, second: 165536).")
  }
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

  # Rootless Podman requires subordinate UID/GID ranges so the kernel can
  # map container UIDs (e.g. 0:42 for /etc/gshadow) into the user namespace.
  # Without these entries `podman pull` fails with "lchown: invalid argument".
  if $manage_subid {
    $subuid_entry = "${user}:${subuid_start}:${subuid_count}"
    $subgid_entry = "${user}:${subgid_start}:${subgid_count}"

    exec { "subuid-${user}":
      command => "/bin/grep -qxF '${subuid_entry}' /etc/subuid || echo '${subuid_entry}' >> /etc/subuid",
      unless  => "/bin/grep -qxF '${subuid_entry}' /etc/subuid",
      require => User[$user],
    }

    exec { "subgid-${user}":
      command => "/bin/grep -qxF '${subgid_entry}' /etc/subgid || echo '${subgid_entry}' >> /etc/subgid",
      unless  => "/bin/grep -qxF '${subgid_entry}' /etc/subgid",
      require => User[$user],
    }

    # After adding subuid/subgid entries podman needs to migrate existing
    # storage to apply the new mappings. The command runs as the target user
    # with a shell so XDG_RUNTIME_DIR is evaluated at runtime. Requires the
    # user manager to be running so /run/user/<uid> already exists.
    exec { "podman-system-migrate-${user}":
      command     => "/usr/bin/bash -c \"export XDG_RUNTIME_DIR=/run/user/\$(id -u); export HOME=${home}; /usr/bin/podman system migrate\"",
      refreshonly => true,
      user        => $user,
      require     => Exec["start-user-manager-${user}"],
      subscribe   => [Exec["subuid-${user}"], Exec["subgid-${user}"]],
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
