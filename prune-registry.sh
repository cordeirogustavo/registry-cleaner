#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

: "${REGISTRY_URL:?REGISTRY_URL is required}"
: "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"
: "${REGISTRY_SERVICE:?REGISTRY_SERVICE is required}"
: "${KEEP:?KEEP is required}"
DRY_RUN="${DRY_RUN:-0}"

registry_config=/etc/docker/registry/config.yml
api="${REGISTRY_URL%/}/v2"
accept="application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json"

log() {
  echo "[$(date '+%F %T %Z')] $*"
}

registry() {
  curl -fsSL -u "$REGISTRY_USERNAME:$REGISTRY_PASSWORD" -H "Accept: $accept" "$@"
}

registry_exec() {
  docker exec "$registry_container" sh -c "$1"
}

list_repositories() {
  local next="/v2/_catalog?n=1000" headers
  headers=$(mktemp)
  while [[ -n $next ]]; do
    registry -D "$headers" "${REGISTRY_URL%/}$next" | jq -r '.repositories[]?'
    next=$(tr -d '\r' <"$headers" | sed -n 's/^[Ll]ink: <\([^>]*\)>; rel="next"$/\1/p')
  done
  rm -f "$headers"
}

manifest_digest() {
  registry -I "$api/$1/manifests/$2" | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
}

# Image "created" dates are unreliable (BuildKit cache and reproducible builds reuse them), so images are ordered by when the registry received each manifest.
manifest_push_times() {
  registry_exec "cd '$storage_root/docker/registry/v2/repositories/$1/_manifests/revisions/sha256' && stat -c '%Y sha256:%n' *"
}

stale_digests() {
  local repo=$1 push_times tags tag digest pushed_at in_use rows=""
  push_times=$(manifest_push_times "$repo")
  tags=$(registry "$api/$repo/tags/list" | jq -r '.tags[]?')
  for tag in $tags; do
    digest=$(manifest_digest "$repo" "$tag")
    pushed_at=$(awk -v digest="$digest" '$2 == digest { print $1 }' <<<"$push_times")
    in_use=0
    grep -q "/$repo:$tag\$" <<<"$images_in_use" && in_use=1
    rows+="${pushed_at:-0} $digest $in_use"$'\n'
  done

  printf '%s' "$rows" | sort -rn | awk -v keep="$KEEP" '
    !($2 in seen) { seen[$2] = 1; order[++n] = $2 }
    $3 == 1 { in_use[$2] = 1 }
    END { for (i = keep + 1; i <= n; i++) if (!in_use[order[i]]) print order[i] }
  '
}

collect_garbage() {
  local output
  output=$(registry_exec "registry garbage-collect --delete-untagged $registry_config")
  log "garbage collector removed $(grep -ciE 'deleting (blob|manifest)' <<<"$output" || true) blobs/manifests"

  # The registry caches blob descriptors in memory; without a restart it can report a collected layer as present and break the next push.
  docker service update --force --detach=false --quiet "$REGISTRY_SERVICE"
  log "$REGISTRY_SERVICE restarted"
}

trap 'log "error: cleanup failed at line $LINENO, nothing else was deleted"' ERR

log "start: keep=$KEEP dry_run=$DRY_RUN registry=$REGISTRY_URL"

registry_container=$(docker ps -q -f "name=$REGISTRY_SERVICE")
if [[ -z $registry_container ]]; then
  log "error: no $REGISTRY_SERVICE container on this node"
  exit 1
fi
storage_root=$(registry_exec "sed -n 's/^ *rootdirectory: *//p' $registry_config")
images_in_use=$(docker service ls --format '{{.Image}}' | sed 's/@.*//')
repositories=$(list_repositories)
count=0

for repo in $repositories; do
  digests=$(stale_digests "$repo")
  for digest in $digests; do
    count=$((count + 1))
    if [[ $DRY_RUN == 1 ]]; then
      log "would delete $repo@$digest"
      continue
    fi
    log "delete $repo@$digest"
    registry -X DELETE -o /dev/null "$api/$repo/manifests/$digest"
  done
done

if [[ $DRY_RUN == 1 ]]; then
  log "done (dry run): $count images would be deleted"
  exit 0
fi

if [[ $count == 0 ]]; then
  log "done: nothing to delete"
  exit 0
fi

collect_garbage
log "done: $count images deleted"
