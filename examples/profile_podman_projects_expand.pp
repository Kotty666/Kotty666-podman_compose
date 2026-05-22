# @summary Helper for profile::podman_projects: substitute the registry
#   placeholder in a project / cron_project hash and merge proxy env vars.
#
# Drop into your profile module as
# `profile/functions/podman_projects/expand.pp`.
#
# The compose hash is rewritten via JSON roundtrip so the placeholder is
# replaced everywhere it appears (image refs, command args, labels, …).
# Registry keys are rewritten in-place so Sensitive[String] passwords
# survive untouched. env_vars get the proxy hash merged in.
#
# After registry substitution and env_vars merging, any compose array
# element of the form `<<splat:KEY>>` is expanded into the
# comma/whitespace-split contents of `env_vars[KEY]` via
# `profile::podman_projects::expand_splat`. The `<<splat:...>>` marker is
# intentionally not Hiera interpolation syntax, so it can be written directly
# in YAML data without escaping. Useful when a web frontend delivers a UUID
# list as a single string but the container needs each
# id as a separate argv element.
#
# @param data
#   Original project/cron_project hash from Hiera.
# @param re
#   Regex (string) matching the placeholder, e.g. '\bharbor\b'.
# @param replacement
#   Real registry FQDN to substitute in.
# @param proxy_env
#   Hash of proxy env vars to merge into `env_vars` (empty hash = no-op).
#
# @return [Hash] the rewritten hash, ready to splat into the define.
#
function profile::podman_projects::expand(
  Hash                 $data,
  String[1]            $re,
  String[1]            $replacement,
  Hash[String, String] $proxy_env,
) >> Hash {

  $_compose_re = $data['compose'] ? {
    undef   => undef,
    default => parsejson(regsubst(to_json($data['compose']), $re, $replacement, 'G')),
  }

  # eyaml decrypts values to plain String, but the module requires
  # Sensitive[String] for registry passwords. Wrap if not already Sensitive.
  $_regs_in = $data['registries'] ? { undef => {}, default => $data['registries'] }
  $_regs    = $_regs_in.reduce({}) |$m, $e| {
    $_pw      = $e[1]['password']
    $_pw_sens = $_pw ? {
      Sensitive => $_pw,
      default   => Sensitive($_pw),
    }
    $_key = regsubst($e[0], $re, $replacement, 'G')
    $m + { $_key => $e[1] + { 'password' => $_pw_sens } }
  }

  # Same story for env_secrets.
  $_secrets_in = $data['env_secrets'] ? { undef => {}, default => $data['env_secrets'] }
  $_secrets    = $_secrets_in.reduce({}) |$m, $e| {
    $_v_sens = $e[1] ? {
      Sensitive => $e[1],
      default   => Sensitive($e[1]),
    }
    $m + { $e[0] => $_v_sens }
  }

  $_env_in = $data['env_vars'] ? { undef => {}, default => $data['env_vars'] }
  $_env    = $_env_in + $proxy_env

  # Expand `<<splat:KEY>>` array entries against the merged env_vars,
  # *after* the registry placeholder has been substituted, so the splat
  # input may itself reference a value that the regex rewrote.
  $_compose = $_compose_re ? {
    undef   => undef,
    default => profile::podman_projects::expand_splat($_compose_re, $_env),
  }

  $_overrides = {
    'compose'     => $_compose,
    'registries'  => $_regs,
    'env_secrets' => $_secrets,
    'env_vars'    => $_env,
  }.filter |$k, $v| { $v != undef }

  $data + $_overrides
}
