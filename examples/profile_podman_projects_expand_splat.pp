# @summary Helper for profile::podman_projects: expand `<<splat:KEY>>`
#   array entries into the comma/whitespace-split contents of
#   `env_vars[KEY]`.
#
# Drop into your profile module as
# `profile/functions/podman_projects/expand_splat.pp`.
#
# Use case: a web frontend writes a UUID list as a single string into
# Hiera (e.g. `env_vars.AZ: "id1, id2 id3"`), but the container needs
# each id as a separate argv element so `python main.py -id id1 id2 id3`
# works. Place `"<<splat:AZ>>"` in any compose array (`command`,
# `entrypoint`, …) and this function expands it inline.
#
# Tokens are recognised only when an array element matches the pattern
# exactly. Embedded substrings are left alone.
#
# @param data
#   The (sub)structure to walk: Hash, Array, or scalar.
# @param env_vars
#   Source map for token resolution. Missing/empty values expand to
#   nothing (the placeholder vanishes).
#
# @return [Any] same shape as $data, with splat tokens expanded.
#
function profile::podman_projects::expand_splat(
  Any                     $data,
  Hash[String[1], String] $env_vars,
) >> Any {
  case $data {
    Hash: {
      $data.reduce({}) |$m, $e| {
        $m + { $e[0] => profile::podman_projects::expand_splat($e[1], $env_vars) }
      }
    }
    Array: {
      $data.reduce([]) |$out, $item| {
        $_m = $item ? {
          String  => $item.match(/^<<splat:([A-Za-z_][A-Za-z0-9_]*)>>$/),
          default => undef,
        }
        $_m ? {
          undef   => $out + [profile::podman_projects::expand_splat($item, $env_vars)],
          default => $out + ($env_vars[$_m[1]] ? {
            undef   => [],
            ''      => [],
            default => $env_vars[$_m[1]].split(/[\s,]+/).filter |$x| { ! empty($x) },
          }),
        }
      }
    }
    default: { $data }
  }
}
