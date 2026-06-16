# AGENTS.md - KubeDB postgres-init-docker

This file provides instructions for AI coding agents working in this repository.

## Project Overview

`postgres-init-docker` produces the init-container image that runs in every KubeDB-managed PostgreSQL pod. It is not a Go module — it is a shell-script image built on Alpine. The image is referenced by the `PostgresVersion` catalog resource as `postgresVersion.Spec.InitContainer.Image` and is injected into pods by `kubedb.dev/postgres/pkg/controller/petset.go`.

## Role in the Pod

When `kubedb.dev/postgres` reconciles a `Postgres` CR it builds a PetSet via `pkg/controller/petset.go:ensurePetSet`. That function calls `GetInitContainers` and `getEnforceFsGroupInitContainers` to produce init containers from this image:

| Container name | Function in petset.go | When |
|---|---|---|
| `postgres-init-container` | `GetInitContainers` | Always |
| `pg-fsgroup-init` | `getEnforceFsGroupInitContainers` | Only when `db.Spec.EnforceFsGroup: true` |

The `postgres-init-container` runs before the main `postgres` container starts. It:
- Initialises PGDATA (`initdb.sh`) for a fresh pod
- Copies run/role scripts to shared volumes (`kubedb.PostgresRunScriptsDir`, `kubedb.PostgresSharedScriptsDir`, `kubedb.PostgresRoleScriptsDir`)
- Configures SSL when `SSL=ON`
- Performs base-backup recovery for replica pods (`do_pg_basebackup.sh`, `recover_replica.sh`)
- Sets up archiver restore entrypoints (`restore.sh`, `config_recovery.conf.sh`)

The `pg-fsgroup-init` container (same image, different command) runs `chmod 0777 /var/pv` to fix volume fsGroup ownership for restrictive pod security contexts.

## Repository Structure

```
Dockerfile          # Multi-stage: builds wal-g from source, final image on alpine
init_scripts/       # Scripts copied into the image at build time
  run.sh            # Primary entrypoint dispatched by the operator
role_scripts/       # PostgreSQL role management scripts
scripts/            # Additional helper scripts:
  initdb.sh                    # pg_ctl initdb for fresh clusters
  do_pg_basebackup.sh          # pg_basebackup replica bootstrap
  recover_replica.sh           # replica recovery helper
  restore.sh                   # archiver restore wrapper
  config_recovery.conf.sh      # writes recovery.conf / postgresql.auto.conf
  copy-data.sh                 # data directory copy helper
  do_pg_recovery_cleanup.sh    # post-recovery cleanup
Makefile            # build / push / container targets
README.md
```

## Key Environment Variables (set by petset.go / GetInitContainers)

| Variable | Set when | Meaning |
|---|---|---|
| `STANDALONE` | Always | `"true"` when replicas=1 and no coordinator; `"false"` for HA clusters |
| `MAJOR_PG_VERSION` | Always | Integer major version (e.g. `16`) |
| `SSL` | Always | `"ON"` or `"OFF"` based on `db.Spec.TLS` |

For remote-replica pods `UpdatePostgresInitContainerForRemoteReplica` in `petset.go` adds additional env vars (`PRIMARY_HOST`, `PRIMARY_PORT`, `SOURCE_DB_*` TLS vars) and extra volume mounts.

## Image Lifecycle

The image is built per PostgreSQL major version. A new `PostgresVersion` CR in `kubedb.dev/apimachinery/apis/catalog` pins the exact digest. The operator resolves the digest at reconcile time via `authn.ImageWithDigest`.

## Build

```bash
# Build image locally (requires Docker)
make container

# Push to registry
make push
```

The Dockerfile embeds `wal-g` (compiled from `github.com/kubedb/wal-g`) and `tini` as the process supervisor.
