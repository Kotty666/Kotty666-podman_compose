# @summary How a project's containers are (re)created when the compose file
#   or .env changes.
#
# * `rolling`        - `up -d --remove-orphans`. Least disruptive; relies on
#                      podman-compose's own change detection. May NOT pick up
#                      `.env` content changes delivered via `env_file:` and
#                      will NOT re-create existing networks.
# * `force-recreate` - `up -d --force-recreate --remove-orphans`. Re-creates
#                      every container so new env values and changed service
#                      network membership are applied cleanly. Does NOT
#                      re-create existing network definitions (subnet/driver).
# * `down-up`        - `down` then `up -d --remove-orphans`. Tears the project
#                      down (including its networks) and brings it back up, so
#                      network topology changes are applied too. Causes a brief
#                      downtime of the whole project.
type Podman_compose::Recreate_strategy = Enum['rolling', 'force-recreate', 'down-up']
