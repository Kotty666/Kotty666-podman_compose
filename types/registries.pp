# @summary Registry credentials hash structure
#
# The password may be supplied either as a `Sensitive[String]` (preferred) or
# as a plain `String`. The latter is accepted because hiera-eyaml decrypts
# `ENC[...]` blocks into ordinary strings unless a `lookup_options`
# `convert_to: 'Sensitive'` is configured. project.pp / cron.pp normalize the
# value to `Sensitive` before handing it to `podman_compose::registry`.
#
# @example
#   {
#     'registry.example.com' => { 'username' => 'deploy', 'password' => Sensitive('secret') },
#     'ghcr.io'              => { 'username' => 'bot',    'password' => 'token',
#                                 'proxy' => { 'HTTPS_PROXY' => 'http://proxy:3128' } },
#   }
#
# The optional `proxy` hash is passed through to `podman_compose::registry`'s
# `proxy_env` so the login can reach a registry that is only accessible through
# a forward proxy.
type Podman_compose::Registries = Hash[
  String[1],
  Struct[{
    username           => String[1],
    password           => Variant[Sensitive[String[1]], String[1]],
    Optional[proxy]    => Hash[String[1], String[1]],
  }]
]
