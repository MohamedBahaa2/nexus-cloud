#!/usr/bin/env bash
# Stage 1: start NexusDrive with plain `docker run`.
# Temporary: for testing in Stage 1 only. Will be deleted once Compose (Stage 2) replaces it.
#
#   ./deploy/docker-run/up.sh
#
# Creates the network, starts the infrastructure containers, waits for them,
# seeds the bucket and test users, then builds and starts every app service
# that has both a Dockerfile and an env file in deploy/docker-run/.
# Safe to run again: running infrastructure is left alone, app services are rebuilt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

NETWORK=nexusdrive
ENV_DIR=deploy/docker-run
TAG="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"

KEYCLOAK_IMAGE=quay.io/keycloak/keycloak:26.4
KCADM="docker exec keycloak /opt/keycloak/bin/kcadm.sh"
TEST_USERS=(demo alice carol dave erin)

# name | Dockerfile | env file | port mapping (host:container)
APP_SERVICES=(
  "user-service|services/user-service/Dockerfile|$ENV_DIR/user-service.env|3003:3003"
  "file-service|services/file-service/Dockerfile|$ENV_DIR/file-service.env|3001:3001"
  "chat-service|services/chat-service/Dockerfile|$ENV_DIR/chat-service.env|3002:3002"
  "web|apps/web/Dockerfile|$ENV_DIR/web.env|5173:8080"
)

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Runs "$@" every 2 s until it succeeds, or fails after $1 seconds.
wait_for() {
  local what=$1 timeout=$2; shift 2
  local waited=0
  printf 'waiting for %s ' "$what"
  until "$@" >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      echo
      die "$what was not ready after ${timeout}s (check: docker logs ${what%% *})"
    fi
    printf '.'
    sleep 2
    waited=$((waited + 2))
  done
  echo ' ok'
}

# Starts an infrastructure container: skips it if running, restarts it if stopped,
# otherwise creates it. Usage: start_infra <name> <docker run args...>
start_infra() {
  local name=$1; shift
  local state
  state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
  case "$state" in
    running) echo "$name: already running" ;;
    "")      echo "$name: starting"; docker run -d --name "$name" --network "$NETWORK" "$@" >/dev/null ;;
    *)       echo "$name: restarting ($state)"; docker start "$name" >/dev/null ;;
  esac
}

# --- Pre-checks ----------------------------------------------------------------

docker info >/dev/null 2>&1 || die "Docker is not reachable (on WSL, enable Docker Desktop's WSL integration)"

if docker ps --format '{{.Names}}' | grep -q '^nd-'; then
  die "the README's nd-* containers are running and use the same ports. Remove them first: docker rm -f \$(docker ps -aq --filter name=^nd-)"
fi

[[ -f "$ENV_DIR/user-service.env" ]] || die "$ENV_DIR/user-service.env is missing"

# One source for the user-service client secret: user-service gets it from its
# env file, and Keycloak gets the same value when it imports the realm.
USER_SERVICE_SECRET="$(sed -n 's/^KEYCLOAK_ADMIN_CLIENT_SECRET=//p' "$ENV_DIR/user-service.env" | tail -n 1 | tr -d '\r')"
[[ -n "$USER_SERVICE_SECRET" ]] || die "KEYCLOAK_ADMIN_CLIENT_SECRET is not set in $ENV_DIR/user-service.env"

# --- Network -------------------------------------------------------------------

log "network"
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "$NETWORK: exists"
else
  docker network create "$NETWORK" >/dev/null
  echo "$NETWORK: created"
fi

# --- Infrastructure ------------------------------------------------------------

log "infrastructure"

# Keycloak in dev mode: its data lives inside the container, and the realm is
# imported on first start (an existing realm is never re-imported).
start_infra keycloak -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  -e NEXUSDRIVE_USER_SERVICE_SECRET="$USER_SERVICE_SECRET" \
  -v "$ROOT/config/keycloak:/opt/keycloak/data/import:ro" \
  "$KEYCLOAK_IMAGE" start-dev --import-realm

# Postgres and Redis are only used by other containers, so they are not published.
start_infra postgres \
  -e POSTGRES_USER=nexusdrive -e POSTGRES_PASSWORD=nexusdrive -e POSTGRES_DB=nexusdrive \
  -v nexusdrive-postgres:/var/lib/postgresql/data \
  postgres:17-alpine

start_infra redis redis:7-alpine

# S3 is published because browsers upload and download through presigned URLs.
start_infra s3 -p 9000:8333 \
  -v nexusdrive-s3:/data \
  chrislusf/seaweedfs:latest server -s3 -dir=/data

start_infra livekit -p 7880:7880 -p 7881:7881 -p 7882:7882/udp \
  livekit/livekit-server:latest --dev --bind 0.0.0.0 --node-ip 127.0.0.1

start_infra drawio -p 8081:8080 jgraph/drawio:latest

# --- Wait and seed -------------------------------------------------------------

log "waiting for infrastructure"
wait_for "postgres" 60 docker exec postgres pg_isready -U nexusdrive -d nexusdrive
wait_for "keycloak (about 30 s)" 180 \
  $KCADM config credentials --server http://localhost:8080 --realm master --user admin --password admin

log "seeding"

# Bucket for files. 200 = created, 409 = already exists; anything else means S3 isn't up yet.
bucket_ready() {
  local code
  code="$(docker run --rm --network "$NETWORK" curlimages/curl:latest \
    -s -o /dev/null -w '%{http_code}' -X PUT http://s3:8333/nexusdrive-files)"
  [[ "$code" == 200 || "$code" == 409 ]]
}
docker pull -q curlimages/curl:latest >/dev/null
wait_for "s3 bucket" 60 bucket_ready

# Test users; each password is the same as the username. demo is the platform admin.
for u in "${TEST_USERS[@]}"; do
  existing="$($KCADM get users -r nexusdrive -q username="$u" -q exact=true --fields id --format csv --noquotes)"
  if [[ -z "$existing" ]]; then
    $KCADM create users -r nexusdrive -s username="$u" -s enabled=true \
      -s email="$u@nexusdrive.local" -s emailVerified=true \
      -s firstName="${u^}" -s lastName=Test >/dev/null
    echo "user $u: created"
  else
    echo "user $u: exists"
  fi
  $KCADM set-password -r nexusdrive --username "$u" --new-password "$u"
done
$KCADM add-roles -r nexusdrive --uusername demo --rolename admin

# --- App services --------------------------------------------------------------

log "app services (tag $TAG)"
started=()
for entry in "${APP_SERVICES[@]}"; do
  IFS='|' read -r name dockerfile envfile ports <<<"$entry"

  if [[ ! -f "$dockerfile" ]]; then
    echo "skipping $name: no $dockerfile yet"
    continue
  fi
  if [[ ! -f "$envfile" ]]; then
    echo "skipping $name: no $envfile yet"
    continue
  fi

  image="nexusdrive/$name:$TAG"
  echo "$name: building $image"
  docker build -q -f "$dockerfile" -t "$image" . >/dev/null

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --init --name "$name" --network "$NETWORK" \
    -p "$ports" --env-file "$envfile" "$image" >/dev/null
  echo "$name: started on localhost:${ports%%:*}"
  started+=("$name")
done

# --- Summary -------------------------------------------------------------------

log "done"
docker ps --filter "network=$NETWORK" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

cat <<EOF

Keycloak admin console: http://localhost:8080  (admin / admin)
Test users:             ${TEST_USERS[*]}  (password = username; demo is admin)
Started app services:   ${started[*]:-none}

Check a service:        curl localhost:3003/ready
Logs:                   docker logs -f user-service
Stop everything:        ./deploy/docker-run/down.sh  (add --volumes to delete data)
EOF
