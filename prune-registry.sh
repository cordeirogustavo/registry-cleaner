#!/usr/bin/env bash
set -euo pipefail

: "${REGISTRY_URL:?REGISTRY_URL is required}"
: "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"
: "${REGISTRY_SERVICE:?REGISTRY_SERVICE is required}"
: "${KEEP:?KEEP is required}"
DRY_RUN="${DRY_RUN:-0}"

api="${REGISTRY_URL%/}/v2"
accept="application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json"

log() {
  echo "[$(date '+%F %T %Z')] $*"
}

registry() {
  curl -fsSL -u "$REGISTRY_USERNAME:$REGISTRY_PASSWORD" -H "Accept: $accept" "$@"
}

manifest_digest() {
  registry -I "$api/$1/manifests/$2" | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
}

image_created_at() {
  local repo=$1 manifest config_digest
  manifest=$(registry "$api/$repo/manifests/$2")
  config_digest=$(jq -r '.config.digest // empty' <<<"$manifest")
  if [[ -z $config_digest ]]; then
    manifest=$(registry "$api/$repo/manifests/$(jq -r '[.manifests[] | select(.platform.os != "unknown")][0].digest' <<<"$manifest")")
    config_digest=$(jq -r '.config.digest' <<<"$manifest")
  fi
  registry "$api/$repo/blobs/$config_digest" | jq -r '.created'
}

stale_digests() {
  local repo=$1 images_in_use=$2 rows="" tag digest in_use
  for tag in $(registry "$api/$repo/tags/list" | jq -r '.tags[]?'); do
    digest=$(manifest_digest "$repo" "$tag")
    in_use=0
    grep -q "/$repo:$tag\$" <<<"$images_in_use" && in_use=1
    rows+="$(image_created_at "$repo" "$digest") $digest $in_use"$'\n'
  done

  printf '%s' "$rows" | sort -r | awk -v keep="$KEEP" '
    !($2 in seen) { seen[$2] = 1; order[++n] = $2 }
    $3 == 1 { in_use[$2] = 1 }
    END { for (i = keep + 1; i <= n; i++) if (!in_use[order[i]]) print order[i] }
  '
}

collect_garbage() {
  local registry_container output
  registry_container=$(docker ps -q -f "name=$REGISTRY_SERVICE")
  if [[ -z $registry_container ]]; then
    log "error: no $REGISTRY_SERVICE container on this node, garbage collector not run"
    return 1
  fi

  output=$(docker exec "$registry_container" registry garbage-collect --delete-untagged /etc/docker/registry/config.yml)
  log "garbage collector removed $(grep -ciE 'deleting (blob|manifest)' <<<"$output" || true) blobs/manifests"

  # The registry caches blob descriptors in memory; without a restart it can report a collected layer as present and break the next push.
  docker service update --force --detach=false --quiet "$REGISTRY_SERVICE"
  log "$REGISTRY_SERVICE restarted"
}

log "start: keep=$KEEP dry_run=$DRY_RUN registry=$REGISTRY_URL"

images_in_use=$(docker service ls --format '{{.Image}}' | sed 's/@.*//')
deleted=0

for repo in $(registry "$api/_catalog?n=10000" | jq -r '.repositories[]?'); do
  for digest in $(stale_digests "$repo" "$images_in_use"); do
    log "delete $repo@$digest"
    deleted=$((deleted + 1))
    [[ $DRY_RUN == 1 ]] || registry -X DELETE -o /dev/null "$api/$repo/manifests/$digest"
  done
done

log "images deleted: $deleted"

if [[ $DRY_RUN == 1 || $deleted == 0 ]]; then
  log "done, garbage collector skipped"
  exit 0
fi

collect_garbage
log "done"
