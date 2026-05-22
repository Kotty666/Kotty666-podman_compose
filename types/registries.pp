# @summary Registry credentials hash structure
# @example
#   {
#     'registry.example.com' => { 'username' => 'deploy', 'password' => Sensitive('secret') },
#     'ghcr.io'              => { 'username' => 'bot',    'password' => Sensitive('token') },
#   }
type Podman_compose::Registries = Hash[
  String[1],
  Struct[{
    username => String[1],
    password => Sensitive[String[1]],
  }]
]
