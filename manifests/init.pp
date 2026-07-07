# @summary Install podman and podman-compose, manage compose projects from Hiera
#
# Installs podman and podman-compose, then iterates over projects defined
# in Hiera to create compose files and systemd services.
#
# @param manage_package
#   Whether to manage the podman package installation.
# @param podman_package
#   Name of the podman package to install.
# @param compose_install_method
#   How to install podman-compose: 'package' (apt/dnf) or 'pip'.
# @param compose_package
#   Package name when using install method 'package'.
# @param compose_pip_package
#   Pip package name when using install method 'pip'.
# @param compose_ensure
#   Ensure state for podman-compose package.
# @param compose_binary
#   Absolute path to the podman-compose binary.
# @param manage_systemd_container
#   Whether to install the systemd-container package (provides machinectl).
#   Useful for opening proper user systemd sessions via
#   `machinectl shell <user>@` with correctly initialized
#   XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS.
# @param systemd_container_package
#   Name of the systemd-container package.
# @param user_compose_dir_name
#   Name of the parent directory under each user's home that holds rootless
#   compose projects. Default: 'compose' (resulting in /home/<user>/compose/<project>).
# @param root_compose_dir
#   Absolute base directory for rootful compose projects. Default: /opt/compose.
# @param projects
#   Hash of podman_compose::project resources, typically from Hiera lookup.
# @param cron_projects
#   Hash of podman_compose::cron resources for scheduled/periodic jobs.
# @param autoscalers
#   Hash of podman_compose::autoscale resources for CPU-based scaling of
#   individual services of existing projects.
#
# @example Basic usage via Hiera
#   include podman_compose
#
# @example Hiera data
#   podman_compose::projects:
#     myapp:
#       user: appuser
#       rootless: true
#       compose:
#         services:
#           web:
#             image: "nginx:1.27"
#             ports:
#               - "8080:80"
#
#   podman_compose::cron_projects:
#     backup:
#       user: backup
#       rootless: true
#       on_calendar: '*-*-* 02:00:00'
#       run_service: restic
#       compose:
#         services:
#           restic:
#             image: "restic/restic:0.17"
#             command: ["backup", "/data"]
#
class podman_compose (
  Boolean                         $manage_package,
  String[1]                       $podman_package,
  Podman_compose::Install_method  $compose_install_method,
  String[1]                       $compose_package,
  String[1]                       $compose_pip_package,
  String[1]                       $compose_ensure,
  Stdlib::Absolutepath             $compose_binary,
  Boolean                         $manage_systemd_container,
  String[1]                       $systemd_container_package,
  String[1]                       $user_compose_dir_name,
  Stdlib::Absolutepath            $root_compose_dir,
  Hash[String[1], Hash]           $projects,
  Hash[String[1], Hash]           $cron_projects,
  Hash[String[1], Hash]           $autoscalers,
) {
  contain podman_compose::install

  $projects.each |String $name, Hash $config| {
    podman_compose::project { $name:
      * => $config,
    }
  }

  $cron_projects.each |String $name, Hash $config| {
    podman_compose::cron { $name:
      * => $config,
    }
  }

  $autoscalers.each |String $name, Hash $config| {
    podman_compose::autoscale { $name:
      * => $config,
    }
  }
}
