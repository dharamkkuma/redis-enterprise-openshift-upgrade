# 02 — The six CRDs operator 8.2 adds

On 8.0 the operator managed four kinds of object. Operator 8.2.0-18.0 adds six
more: users, ACL rules, and roles. All six were applied and inspected on a live
cluster. One minimal example per CRD is in [examples/crds-8.2/](../examples/crds-8.2/).

## Already there on 8.0

| Kind | Short name | What it is |
| --- | --- | --- |
| RedisEnterpriseCluster | `rec` | The cluster itself |
| RedisEnterpriseDatabase | `redb` | One database on that cluster |
| RedisEnterpriseRemoteCluster | `rerc` | Link to another cluster (Active-Active) |
| RedisEnterpriseActiveActiveDatabase | `reaadb` | One Active-Active database across linked clusters |

## New in 8.2

| Kind | Short name | What you get |
| --- | --- | --- |
| RedisEnterpriseACL | `reacl` | A Redis ACL rule (e.g. `~* +@read`). Roles reference it. |
| RedisEnterpriseUser | `reuser` | A cluster-local user. Password from a Secret (key `password`); `passwordMode: Single` or `Rotatable`; `authMethod: Basic` or `Certificate`. |
| RedisEnterpriseClusterRole | `recrole` | A role for **every** database on the REC, plus a cluster management permission (`Admin`, `ClusterMember`, `ClusterViewer`, `DBMember`, `DBViewer`, `UserManager`, `None`). |
| RedisEnterpriseClusterRoleBinding | `recrolebinding` | Attaches users to a cluster role. |
| RedisEnterpriseRole | `rerole` | A role for **selected** databases. Management permission limited to `DBMember`, `DBViewer`, `None`. `scopes` is required. |
| RedisEnterpriseRoleBinding | `rerolebinding` | Attaches users to a scoped role. |

## How they fit

```
Secret (password)
    |
RedisEnterpriseUser
    |-- RedisEnterpriseClusterRoleBinding --> RedisEnterpriseClusterRole --> RedisEnterpriseACL
    |
    -- RedisEnterpriseRoleBinding ---------> RedisEnterpriseRole ---------> RedisEnterpriseACL
                                                  |
                                          scope: REDB(s), or internal bdb
```

The ACL is the data rule (`~* +@read` = any key, read commands only). The
management role is separate — `ClusterViewer` can look at the cluster,
`DBViewer` at one database. Neither is implied by the ACL.

## What the cluster does with them (observed)

- Each CR gets a cluster-side object with a deterministic name:
  `role#<namespace>#<cr-name>`, `clusterrole#<namespace>#<cr-name>`. The uid is
  written back to `status.uid` on the CR.
- The user's status shows the effective bindings:
  `signinStatus: Active`, `rolesDisplay: <bound roles>`.
- A role CR is created in the cluster **even before its scope database exists**:
  the operator logs `... not found - skipping`, keeps reconciling, and attaches
  the role when the database appears. Declaring roles before databases works.
- Scopes also accept a **label selector** (`selector.matchLabels`): a role
  defined once picks up any REDB created later with that label. This removes the
  ordering dependency between "cluster chart" and "database chart" entirely.
  (Selector pickup is schema-confirmed; exercise it once in your own cluster
  before relying on it.)
- A **REAADB is not a valid scope kind**. For an Active-Active database, scope
  with `kind: bdb` and the database name (observed: attached to that database's
  uid).
- LDAP groups map onto these roles by uid — see
  [03-ldap-and-rbac.md](03-ldap-and-rbac.md).

## 8.0 → 8.2 behaviour worth planning around

- Between the operator approval and the REC roll, the operator refuses to
  reconcile the REC (`reconciliation will not continue until REC is upgraded`)
  and admission denies database changes: `REC is frozen, can't modify REDBs`.
  The new RBAC CRs still reconcile during that window — only database CRUD is
  frozen.
- `redisEnterpriseImageSpec.digestHash` together with
  `upgradeSpec.autoUpgradeRedisEnterprise: true` is rejected (`specStatus:
  Invalid`). 8.0.18 accepted it. Remove the digest or disable auto-upgrade when
  the operator moves.
- Roles, ACLs and users created through the REST API / UI / `rladmin` on 8.0
  stay in the cluster with their uids. The CRDs do **not** adopt them — a CR
  with the same name creates a new, prefixed role alongside the old one.
