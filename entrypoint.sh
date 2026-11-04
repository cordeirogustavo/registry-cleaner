#!/usr/bin/env bash
set -euo pipefail

: "${REGISTRY_URL:?REGISTRY_URL is required}"
: "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"
: "${REGISTRY_SERVICE:?REGISTRY_SERVICE is required}"
: "${KEEP:?KEEP is required}"
: "${CRON_SCHEDULE:?CRON_SCHEDULE is required}"
RUN_ON_START="${RUN_ON_START:-0}"
DRY_RUN="${DRY_RUN:-0}"

if [[ ! -S /var/run/docker.sock ]]; then
  echo "error: /var/run/docker.sock is not mounted; map it from the host in the app's persistent directories" >&2
  exit 1
fi

if [[ -z $(docker ps -q -f "name=$REGISTRY_SERVICE") ]]; then
  echo "error: no $REGISTRY_SERVICE container on this node; pin the app to the CapRover leader node" >&2
  exit 1
fi

if ! curl -fsS -o /dev/null -u "$REGISTRY_USERNAME:$REGISTRY_PASSWORD" "${REGISTRY_URL%/}/v2/"; then
  echo "error: cannot authenticate to $REGISTRY_URL as $REGISTRY_USERNAME" >&2
  exit 1
fi

crontab_file=/etc/registry-cleaner.crontab
echo "$CRON_SCHEDULE /usr/local/bin/prune-registry" >"$crontab_file"

echo "registry-cleaner ready: schedule='$CRON_SCHEDULE' tz='${TZ:-UTC}' keep=$KEEP dry_run=$DRY_RUN"

if [[ $RUN_ON_START == 1 ]]; then
  /usr/local/bin/prune-registry
fi

exec supercronic -passthrough-logs "$crontab_file"
