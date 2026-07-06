# @summary Manage a container registry login for a specific user
#
# Runs `podman login` with credentials piped via stdin (no password
# in the process list). A SHA256 sentinel file tracks credential
# changes — if username or password change in Hiera, the login is
# re-executed on the next Puppet run.
#
# Can be used standalone or auto-created via the `registries`
# parameter on podman_compose::project / podman_compose::cron.
#
# @param server
#   Registry FQDN (e.g. 'registry.example.com', 'ghcr.io').
# @param username
#   Registry username or token name.
# @param password
#   Registry password or access token (Sensitive).
# @param user
#   System user to authenticate. Determines auth.json location.
# @param rootless
#   Whether the user runs rootless podman.
# @param ensure
#   'present' to log in, 'absent' to log out and remove sentinel.
# @param proxy_env
#   HTTP(S) proxy environment variables (e.g.
#   { 'HTTP_PROXY' => 'http://proxy:3128', 'HTTPS_PROXY' => ..., 'NO_PROXY' => ... })
#   injected into the `podman login` exec so authentication to a registry
#   reachable only through a forward proxy works. Empty hash (default) = no proxy.
#
# @example Standalone usage
#   podman_compose::registry { 'appuser@registry.example.com':
#     server   => 'registry.example.com',
#     username => 'deploy',
#     password => Sensitive('s3cret'),
#     user     => 'appuser',
#     rootless => true,
#   }
#
# @example Via Hiera (auto-created by project/cron)
#   podman_compose::projects:
#     myapp:
#       user: appuser
#       registries:
#         registry.example.com:
#           username: deploy
#           password: ENC[PKCS7,...]
#
define podman_compose::registry (
  String[1]                  $server,
  String[1]                  $username,
  Sensitive[String[1]]       $password,
  String[1]                  $user      = 'root',
  Boolean                    $rootless  = true,
  Enum['present', 'absent']  $ensure    = 'present',
  Hash[String[1], String[1]] $proxy_env = {},
) {
  # Sentinel directory for credential change tracking
  $_sentinel_dir = $rootless ? {
    true  => "/home/${user}/.config/containers/.puppet-registry-sentinels",
    false => '/root/.config/containers/.puppet-registry-sentinels',
  }

  # Deterministic sentinel filename from server FQDN
  $_safe_server  = regsubst($server, '[^a-zA-Z0-9._-]', '_', 'G')
  $_sentinel     = "${_sentinel_dir}/${_safe_server}"

  # Hash of credentials for change detection — if username or password
  # change, the sentinel content changes and Puppet re-runs the login.
  $_cred_hash = sha256("${username}:${password.unwrap}:${server}")

  # Shell wrapper for rootless
  $_scu = $rootless ? {
    true  => '/usr/bin/bash -c \'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus &&',
    false => '/usr/bin/bash -c \'',
  }

  # Puppet-agent typically runs from /root. When `user => <non-root>` is set
  # without `cwd`, the spawned shell tries to chdir to /root and fails with
  # "cannot chdir to /root: Permission denied". /tmp is universally readable.
  $_cwd = '/tmp'

  # Pass credentials via the process environment instead of interpolating
  # them into the command string. Puppet's `environment` parameter sets
  # these on the spawned process; bash inherits them and expands
  # "$PODMAN_LOGIN_PW" exactly once — no shell re-parsing — so passwords
  # and usernames containing $, `, ', ", \, !, spaces, … are passed
  # through literally.
  # Proxy vars (if any) are appended so `podman login` can traverse a
  # forward proxy to reach the registry. NO_PROXY entries let the login
  # bypass the proxy for internal registries.
  $_proxy_env = $proxy_env.map |$k, $v| { "${k}=${v}" }

  $_login_env = [
    "PODMAN_LOGIN_PW=${password.unwrap}",
    "PODMAN_LOGIN_USER=${username}",
    "PODMAN_LOGIN_SERVER=${server}",
  ] + $_proxy_env

  if $ensure == 'absent' {
    # Logout and remove sentinel
    exec { "podman-logout-${user}-${_safe_server}":
      command     => "${_scu} /usr/bin/podman logout \"\$PODMAN_LOGIN_SERVER\" || true'",
      user        => $user,
      cwd         => $_cwd,
      environment => $_login_env,
      onlyif      => "${_scu} /usr/bin/podman login --get-login \"\$PODMAN_LOGIN_SERVER\" 2>/dev/null'",
    }

    file { $_sentinel:
      ensure => absent,
    }
  } else {
    # Ensure sentinel directory
    exec { "mkdir-sentinel-dir-${user}":
      command => "/usr/bin/mkdir -p ${_sentinel_dir}",
      creates => $_sentinel_dir,
      user    => $user,
      cwd     => $_cwd,
    }

    # The sentinel file holds a hash of the credentials.
    # When it changes, Puppet replaces the file and triggers the login exec.
    file { $_sentinel:
      ensure  => file,
      owner   => $user,
      mode    => '0600',
      content => $_cred_hash,
      require => Exec["mkdir-sentinel-dir-${user}"],
      notify  => Exec["podman-login-${user}-${_safe_server}"],
    }

    # Login via stdin — password never appears in the process command line
    # (only in the process environment, which is restricted to root + the
    # target user). Credentials are sourced from env vars, so the bash
    # parser never sees the literal values.
    # refreshonly: only runs when sentinel file changes (new creds or first run).
    exec { "podman-login-${user}-${_safe_server}":
      command     => "${_scu} /usr/bin/printf \"%s\" \"\$PODMAN_LOGIN_PW\" | /usr/bin/podman login --username \"\$PODMAN_LOGIN_USER\" --password-stdin \"\$PODMAN_LOGIN_SERVER\"'",
      user        => $user,
      cwd         => $_cwd,
      environment => $_login_env,
      refreshonly => true,
      logoutput   => false,  # never log output (could leak credential errors)
    }

    # Also run on first apply if not yet logged in
    exec { "podman-login-initial-${user}-${_safe_server}":
      command     => "${_scu} /usr/bin/printf \"%s\" \"\$PODMAN_LOGIN_PW\" | /usr/bin/podman login --username \"\$PODMAN_LOGIN_USER\" --password-stdin \"\$PODMAN_LOGIN_SERVER\"'",
      user        => $user,
      cwd         => $_cwd,
      environment => $_login_env,
      unless      => "${_scu} /usr/bin/podman login --get-login \"\$PODMAN_LOGIN_SERVER\" 2>/dev/null | /usr/bin/grep -qxF \"\$PODMAN_LOGIN_USER\"'",
      logoutput   => false,
      require     => File[$_sentinel],
    }
  }
}
