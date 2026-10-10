# 01 — The upgrade guide

How an upgrade actually moves on OpenShift, in the order you will do it.

## The three versions

| Thing | What it is | Where its version lives |
| --- | --- | --- |
| Operator | The controller from OperatorHub. Watches the CRs, starts rolls. Stores no data. | The OLM subscription / CSV |
| REC | The Redis Enterprise cluster: the pods. One REC serves every database in its namespace. | `redisEnterpriseImageSpec` on the live REC |
| Database | Each `RedisEnterpriseDatabase` (REDB) or `RedisEnterpriseActiveActiveDatabase` (REAADB) | `spec.redisVersion` (REDB), `spec.globalConfigurations.redisVersion` (REAADB), or nothing at all |

Approving an operator InstallPlan does not change the REC. Rolling the REC does
not change a database. Each database is upgraded on its own, after the REC is
done. Hold onto that — most upgrade surprises come from treating the three as one.

## Know what you get before you start

Redis releases new Redis Software **bundled with a set of database versions**.
The release notes for the target operator name that bundle: the REC image tag,
and the database versions that release can run. Compare it with what runs today:

- If the bundle adds nothing you need, the window is not worth taking.
- Every database that will *stay on its current version* must exist in the new
  bundle. Check this explicitly.
- The operator must support your OpenShift version (supported-distributions
  matrix in the release notes).
- The client library check belongs to the **database** step, not the REC step.
  A REC-only upgrade leaves every database on its existing Redis version — the
  clients see no version change.

You can also ask the cluster itself which database versions a REC can run —
this changes nothing:

```bash
oc exec -n redis-ent <rec-pod> -c redis-enterprise-node -- \
  rladmin upgrade db <db:id> redis_version
# -> 6.2, 7.2, 7.4, 8.0, 8.2, 8.4, 8.6   (example)
```

## Operator upgrade: channels, Upgrade Status, InstallPlan

Typical install: OperatorHub, update approval **Manual**. Nothing upgrades until
someone approves an InstallPlan.

**The channel decides what Approve installs.** OLM offers the *head of the
channel*, not the next build in the catalog.

| Channel | What Approve installs |
| --- | --- |
| `production` | The newest operator. Skips every intermediate line. |
| A version channel, e.g. `8.0.18-14.2` | The head of that line. |

Flow:

1. Operators → Installed Operators → Redis Enterprise Operator → Subscription.
2. Set the **Update channel** to the line you want.
3. Upgrade Status now shows the available upgrade. **Preview the InstallPlan**
   and confirm the CSV name matches your target.
4. **Delete any stale InstallPlan first.** A plan created under the old channel
   survives the channel change; approving it installs the wrong version.
   (Observed: a plan for the `production` head survived a switch to a version
   channel and would have skipped two releases.)
5. Approve. Wait for the new CSV to reach `Succeeded`. Do not approve a second plan.

```bash
oc get csv -n redis-ent
oc get installplan -n redis-ent
oc get pods -n redis-ent -l name=redis-enterprise-operator
```

A CRD change can make a later downgrade impossible — check the release notes
before approving.

## REC upgrade: two options

One field chooses: `spec.upgradeSpec.autoUpgradeRedisEnterprise`. Set it before
the operator approval. Changing only this field must not restart pods.

### Automatic — REC rolls with the operator

```yaml
spec:
  upgradeSpec:
    autoUpgradeRedisEnterprise: true
```

The REC rolls as soon as the operator upgrade completes, same approval. The
operator puts the REC on the image bundled with that operator. One pod at a
time; databases keep their Redis version. There is no separate window for the
pod roll, and the image cannot be pinned with a digest.

**Compatibility trap (hit in practice):** 8.2 rejects a REC spec that has both
`redisEnterpriseImageSpec.digestHash` and `autoUpgradeRedisEnterprise: true` —
spec status goes `Invalid`, the operator freezes reconciliation, and admission
refuses database changes (`REC is frozen`) until you remove the digest or turn
auto-upgrade off. Earlier operators accepted the combination.

### Manual — REC is triggered in the window

```yaml
spec:
  upgradeSpec:
    autoUpgradeRedisEnterprise: false
  redisEnterpriseImageSpec:
    imagePullPolicy: IfNotPresent
    repository: registry.connect.redhat.com/redislabs/redis-enterprise
    versionTag: "<tag-from-operator-release-notes>"
```

Approving the operator leaves the REC image alone. You set `versionTag` on the
live REC in the same window (take the tag from the operator release notes).
Change only `versionTag` — not `bootstrapperImageSpec`. If a digest is pinned,
change it too: `versionTag` alone does not move pods when a digest is set.

### Monitoring the roll

```bash
oc get rec -n redis-ent
oc rollout status sts/<rec-name> -n redis-ent
oc exec -n redis-ent <pod-that-is-still-2/2> -c redis-enterprise-node -- rladmin status
```

| REC state | Meaning |
| --- | --- |
| `Upgrade` | Rolling. One pod down at a time. Stay and watch. |
| `Running` | Roll finished. |
| `InvalidUpgrade` | Stop. Read the operator log. |

Expected sights mid-roll: one pod `Terminating`/`ContainerCreating` while the
cluster runs on the remaining nodes; a replica `ERROR: timed out` while its pod
is down (clears when the pod is `2/2`); a replica `OK, OLD REDIS VERSION` just
after rejoining (clears on its own — the **database** version has not changed).
Stop if the primary/master shows `ERROR: timed out`.

Pass: all pods on the new image, REC `Running`, license `Valid`, primaries and
replicas on different pods, and `rladmin status databases extra all` still shows
the **old** `REDIS_VERSION` — the database step has not happened yet.

## Database upgrade

Only after the REC is `Running` on the new image everywhere it needs to be.

`redisUpgradePolicy` on the REC is `major` (default) or `latest`. `major` keeps
an existing database on its current version when only the REC moves. Prefer an
explicit version string; an empty `redisVersion` is not `latest`.

Check the current version first — `oc get reaadb` does not show it:

```bash
oc exec -n redis-ent <rec-pod> -c redis-enterprise-node -- \
  redis-cli -p <port> INFO server | grep redis_version
```

The Cluster Manager UI shows the same value.

**Path A — `redisVersion` is in the database YAML (the clean path).** Change the
string, apply the file. For a REDB: `spec.redisVersion`, applied on its cluster.
For a REAADB: `spec.globalConfigurations.redisVersion`, applied on **one site
only** — the other site follows (observed: applying `"8.6"` on one site moved
both sites to running `8.6.2`, replication stayed up). Both sites need operator
8.0.2-2 or later for the follow behaviour. The site you applied can show
`active-change-pending` while the other is already done; accept when both are
`active` and `REDIS_VERSION` matches.

**Path B — no `redisVersion` in the YAML.** The database stays on the version it
was created with; a REC upgrade never moves it. Upgrade each database on each
site by hand:

```bash
oc exec -n redis-ent <rec-pod> -c redis-enterprise-node -- \
  rladmin upgrade db <db:id> redis_version 8.6 preserve_roles force
```

`completed - SMUpgradeBDB` / `Done` finishes **this site's copy only**. Run the
same on the second site. Never both at once. UI and REST API are the same manual
action under the same rule.

The client-library check belongs here: the library must support the Redis OSS
version being applied (`"8.6"` runs as `8.6.2`). Prove it in a lower environment
first.

## Active-Active: one site at a time

Each site has its own operator and its own REC. Upgrade site 1 fully (operator,
then REC), confirm it is `Running` on the new image and replication is `up`,
and only then touch site 2. Mixed versions between sites are supported during
the upgrade, but do not linger there, and make no other changes while split.

Databases: after both sites run the new REC, upgrade each database once —
Path A applies on one site only; Path B needs the manual command on each site.

## After

- Same `REDIS_VERSION` for every database in scope, on every site.
- Shards `OK`, primary and replica on different pods.
- Active-Active replication `up`, lag back to its pre-upgrade baseline.
- A key written on one site reads back on the other.
- Take a backup before database version changes — restore from backup is the
  only realistic rollback for that step.
