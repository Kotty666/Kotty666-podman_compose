# @summary Wrapper profile that injects environment-derived registry URL
#   and HTTP proxy into podman_compose project / cron_project definitions.
#
# This file is provided as an EXAMPLE — it is not part of the
# podman_compose module itself, since it depends on site-specific
# functions (`get_environment`, `get_http_proxy`).
# Drop it into your own profile module as
# `profile/manifests/podman_projects.pp` and adjust to taste.
#
# Hiera authors use the literal string defined by `registry_placeholder`
# (default: 'harbor') wherever the real registry FQDN should appear.
# The profile substitutes the placeholder with the value returned by
# `get_environment('harbor')` before declaring resources,
# and injects HTTP_PROXY / HTTPS_PROXY / NO_PROXY into env_vars based
# on `get_http_proxy()`.
#
# @param projects
#   Hiera hash of podman_compose::project definitions.
# @param cron_projects
#   Hiera hash of podman_compose::cron definitions.
# @param registry_placeholder
#   Token replaced with the real registry FQDN. Matched as a whole word.
# @param harbor_proxy
#   When true (typically set per-environment via Hiera), the registry FQDN
#   is appended to NO_PROXY so Harbor is reached directly while external
#   image pulls still go through the proxy. Default false.
#
# @example Hiera
#   profile::podman_projects::cron_projects:
#     help-sync:
#       user: helpsync
#       rootless: true
#       on_calendar: '*-*-* 04,12,16:05:00'
#       run_service: sync
#       registries:
#         harbor/help:
#           username: deploy
#           password: ENC[PKCS7,...]
#       env_vars:
#         UUID: "uuid-1,uuid-2,uuid-3"
#       compose:
#         services:
#           sync:
#             image: "harbor/help/sync:latest"
#             env_file:
#               - .env
#
class profile::podman_projects (
  Hash[String[1], Hash] $projects             = {},
  Hash[String[1], Hash] $cron_projects        = {},
  String[1]             $registry_placeholder = 'harbor',
  Boolean               $harbor_proxy         = false,
) {
  include podman_compose

  $_harbor     = get_environment('harbor')
  $_http_proxy = get_http_proxy()

  # Whole-word match on the placeholder.
  $_re = "\\b${registry_placeholder}\\b"

  # When proxying, bypass the proxy for Harbor itself (direct/internal),
  # so only external image pulls traverse the proxy.
  $_noproxy = $harbor_proxy ? {
    true    => "localhost,127.0.0.1,${_harbor}",
    default => 'localhost,127.0.0.1',
  }

  $_proxy_env = $_http_proxy ? {
    undef   => {},
    ''      => {},
    default => {
      'HTTP_PROXY'  => $_http_proxy,
      'HTTPS_PROXY' => $_http_proxy,
      'NO_PROXY'    => $_noproxy,
    },
  }

  $projects.each |String[1] $pname, Hash $pdata| {
    podman_compose::project { $pname:
      * => profile::podman_projects::expand($pdata, $_re, $_harbor, $_proxy_env),
    }
  }

  $cron_projects.each |String[1] $cname, Hash $cdata| {
    podman_compose::cron { $cname:
      * => profile::podman_projects::expand($cdata, $_re, $_harbor, $_proxy_env),
    }
  }
}
