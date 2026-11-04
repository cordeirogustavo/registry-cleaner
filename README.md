# registry-cleaner

Docker Hub: [`guhcordeiro/registry-cleaner`](https://hub.docker.com/r/guhcordeiro/registry-cleaner)

Scheduled cleanup for the [CapRover](https://caprover.com) self-hosted Docker registry.

CapRover's registry never deletes images on its own: every deploy pushes a new
one and the disk grows forever. CapRover's built-in **Disk Cleanup** only
removes local images on the leader node, not what is stored in the registry.

`registry-cleaner` runs as a regular CapRover app and, on a cron schedule:

1. Keeps the newest `KEEP` images of **every** repository in the registry and
   deletes the rest. Tags pointing to the same image (`latest` and
   `sha-<commit>`) count as one image.
2. Never deletes an image a Swarm service is currently running, even when it is
   older than the newest `KEEP` (e.g. after a rollback).
3. Runs the registry garbage collector, so the disk space is actually freed.
4. Restarts the registry service, clearing its in-memory layer cache so the
   next push does not reference a collected layer.

All configuration comes from environment variables; the output of every run
shows up in the app logs.

## Requirements

- CapRover with the **self-hosted** Docker registry, with delete enabled
  (`REGISTRY_STORAGE_DELETE_ENABLED=true`, CapRover's default).
- The app must run on the **leader node**, where the `captain-registry`
  container runs.
- The host Docker socket mounted into the container (`/var/run/docker.sock`),
  used to list running services, run the garbage collector and restart the
  registry.

## Environment variables

See [`.env.example`](.env.example).

| Variable | Required | Description | Example |
|---|---|---|---|
| `REGISTRY_URL` | yes | Registry URL, including the port. | `https://registry.example.com:996` |
| `REGISTRY_USERNAME` | yes | Registry user. | `captain` |
| `REGISTRY_PASSWORD` | yes | Registry password (CapRover: **Cluster → Docker Registry Configuration**). | |
| `REGISTRY_SERVICE` | yes | Swarm service name of the registry. | `captain-registry` |
| `KEEP` | yes | Images to keep per repository. | `3` |
| `CRON_SCHEDULE` | yes | When to run, in [cron syntax](https://crontab.guru). | `0 3 * * 6` (Saturdays, 03:00) |
| `TZ` | no | Timezone for `CRON_SCHEDULE` and log timestamps. Defaults to `UTC`. | `America/Sao_Paulo` |
| `DRY_RUN` | no | `1` lists what would be deleted without deleting anything. Defaults to `0`. | `1` |
| `RUN_ON_START` | no | `1` also runs a cleanup as soon as the container starts. Defaults to `0`. | `1` |

> Pick a `CRON_SCHEDULE` when no deploy runs: the garbage collector is not safe
> while an image is being pushed.

## Installing on CapRover

1. **Apps → Create New App**, name it `registry-cleaner`, check **Has
   Persistent Data**.
2. **App Configs**:
   - **Environment Variables**: set the variables above (the bulk edit accepts
     the contents of `.env.example`).
   - **Persistent Directories**: add **Path in App** `/var/run/docker.sock`,
     choose **Set specific host path**, **Path on Host** `/var/run/docker.sock`.
   - **Node ID**: the leader node ID (`docker node ls`, the one marked
     `Leader`).
   - **Do not expose as web-app**: checked.
   - **Save & Update**.
3. **Deployment → Deploy via ImageName**: `guhcordeiro/registry-cleaner:latest`.

The logs should show:

```
registry-cleaner ready: schedule='0 3 * * 6' tz='America/Sao_Paulo' keep=3 dry_run=0
```

If the container keeps restarting, the logs say why: a missing variable, the
Docker socket not mounted, the app not on the leader node, or wrong registry
credentials.

## Usage

| To | Do |
|---|---|
| See what would be deleted | `DRY_RUN=1`, `RUN_ON_START=1`, **Save & Update**, read the logs. |
| Run a cleanup now | `RUN_ON_START=1`, **Save & Update**. |
| Change how many images to keep or when | Edit `KEEP` / `CRON_SCHEDULE`, **Save & Update**. |
| Pause the cleanup | Set **Instance Count** to `0`. |
| Upgrade | **Deploy via ImageName** again with `guhcordeiro/registry-cleaner:latest` (CapRover pulls the new image). |

Every run logs each deleted image (`delete <repository>@<digest>`), the total,
and how many blobs the garbage collector removed.

## Running without CapRover

On the node that runs the registry:

```bash
cp .env.example .env   # fill in REGISTRY_PASSWORD
docker run -d --name registry-cleaner --restart unless-stopped \
  --env-file .env \
  -v /var/run/docker.sock:/var/run/docker.sock \
  guhcordeiro/registry-cleaner:latest
```

## Publishing

`.github/workflows/publish.yml` builds the image for `linux/amd64` and
`linux/arm64` and pushes it to Docker Hub on every push to `main`, as
`guhcordeiro/registry-cleaner:latest` and `guhcordeiro/registry-cleaner:sha-<short-commit>`.
Pin a `sha-` tag in CapRover to stay on a specific build.

Repository settings:

| Name | Kind | Value |
|---|---|---|
| `DOCKERHUB_USERNAME` | Variable | Docker Hub user or organization (`guhcordeiro`) |
| `DOCKERHUB_TOKEN` | Secret | Docker Hub access token with write access |

## Security

The container has full access to the host Docker daemon through the mounted
socket. It exposes no ports and only talks to the registry and the local
Docker API, but treat it with the same care as root access to the node.
