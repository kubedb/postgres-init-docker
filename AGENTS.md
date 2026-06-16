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

The `postgres-init-container` runs before the main `postgres` container starts. Its entrypoint is `init_scripts/run.sh`, which:

1. Clears `/run_scripts/` and copies `/tmp/scripts/*` → `/scripts/` (the shared scripts volume).
2. Copies role-specific scripts based on mode:
   - **Remote replica** (`REMOTE_REPLICA=true`): copies `role_scripts/$MAJOR_PG_VERSION/standby/*` → `/run_scripts/role/` directly.
   - **Standalone** (`STANDALONE=true`, i.e. single replica): copies `role_scripts/$MAJOR_PG_VERSION/primary/*` → `/run_scripts/role/` directly.
   - **HA cluster** (replicas > 1, coordinator present): copies the full `role_scripts/$MAJOR_PG_VERSION/` tree (both `primary/` and `standby/` subdirs) → `/role_scripts/`. The **pg-coordinator** then decides the role at runtime and calls `AddRoleBasedScripts()` to copy the correct subset to `/run_scripts/role/`.
3. For PG version ≤ 11 keeps `config_recovery.conf.sh` and `do_pg_recovery_cleanup.sh`; removes them for PG ≥ 12.
4. Copies TLS certs to `/tls/` and applies `chmod 0600` when `SSL=ON` or `SOURCE_SSL=ON`.

### Role scripts layout

```
role_scripts/
  <major_version>/       # e.g. 16/
    primary/
      run.sh             # starts postgres as primary
      start.sh           # pg_ctl start wrapper
      db.sh              # post-start DB setup
      postgresql.conf    # primary-specific GUCs
    standby/
      run.sh             # starts postgres in standby/recovery mode
      warm_standby.sh    # streaming replication setup
      remote-replica.sh  # remote replica variant
      postgresql.conf    # standby-specific GUCs
```

The presence of `/run_scripts/role/run.sh` is the signal to the main `postgres` container that a role has been assigned and the server should start. Absence means it waits.

### Script handoff between init container and coordinator

```
init container (run.sh)
  └─ HA mode: copies role_scripts/<ver>/{primary,standby}/ → /role_scripts/
        │
        ▼
pg-coordinator (AddRoleBasedScripts)          ← called on every Raft role change
  └─ copies /role_scripts/<raftRole>/* → /run_scripts/role/
        │
        ▼
postgres container
  └─ exec /run_scripts/role/run.sh           ← starts as primary or standby
```

`RemoveRoleBasedScripts()` clears `/run_scripts/` before a role transition so the postgres process stops cleanly.

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
