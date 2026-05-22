# @summary Ensure state for a podman-compose project
type Podman_compose::Ensure = Enum['running', 'stopped', 'absent']
