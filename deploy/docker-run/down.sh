#!/usr/bin/env bash
# Stage 1: stop and remove everything up.sh started.
# Temporary: for testing in Stage 1 only. Will be deleted once Compose (Stage 2) replaces it.
#
#   ./deploy/docker-run/down.sh             # keeps the Postgres and S3 data volumes
#   ./deploy/docker-run/down.sh --volumes   # also deletes them
set -euo pipefail

NETWORK=nexusdrive
APP_CONTAINERS=(web chat-service file-service user-service)
INFRA_CONTAINERS=(drawio livekit s3 redis postgres keycloak)
VOLUMES=(nexusdrive-postgres nexusdrive-s3)

remove_volumes=false
case "${1:-}" in
  "") ;;
  -v|--volumes) remove_volumes=true ;;
  -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
  *) echo "unknown option: $1 (use --volumes or --help)" >&2; exit 1 ;;
esac

docker info >/dev/null 2>&1 || { echo "error: Docker is not reachable" >&2; exit 1; }

# App services first, then the infrastructure they depend on.
for name in "${APP_CONTAINERS[@]}" "${INFRA_CONTAINERS[@]}"; do
  if docker inspect "$name" >/dev/null 2>&1; then
    docker rm -f "$name" >/dev/null
    echo "$name: removed"
  fi
done

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  docker network rm "$NETWORK" >/dev/null
  echo "network $NETWORK: removed"
fi

if $remove_volumes; then
  for vol in "${VOLUMES[@]}"; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
      docker volume rm "$vol" >/dev/null
      echo "volume $vol: removed"
    fi
  done
else
  echo "volumes kept: ${VOLUMES[*]} (run with --volumes to delete them)"
fi
