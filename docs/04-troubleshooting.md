# 04 — Troubleshooting: failure modes actually observed

Every entry below was hit on a live cluster during operator 8.0.18/8.0.20 →
8.2 upgrades and the RBAC/LDAP testing. Symptom, cause, fix.

## The InstallPlan that survived the channel change

**Symptom.** You set the Update channel to a version line (e.g. `8.0.18-14.2`),
but the waiting InstallPlan is for the `production` head (e.g. 8.2.0-18.0).

**Cause.** OLM created that plan while the channel was `production`. Changing
the channel does not delete an unapproved plan. Approving it skips the releases
in between.

**Fix.** Delete the stale plan before approving; OLM then creates the correct
one and leaves it unapproved (Manual):

```bash
oc get installplan -n redis-ent
oc delete installplan <stale-plan> -n redis-ent
```

## REC frozen: digest plus automatic upgrade

**Symptom.** After the operator became 8.2, REC `specStatus: Invalid`, and
admission refused database changes: `REC is frozen, can't modify REDBs`.

**Cause.** The REC spec had both `redisEnterpriseImageSpec.digestHash` and
`upgradeSpec.autoUpgradeRedisEnterprise: true`. 8.2 rejects the combination
(`digest hashes cannot be used together with auto upgrade`); 8.0.18 accepted
it. The operator also logged `reconciliation will not continue until REC is
upgraded` — the REC was still on the previous image.

**Fix.** Remove the digest and point `versionTag` at the image the operator
bundles (operator log names it, e.g. `expected_version`), or set
`autoUpgradeRedisEnterprise: false`. The roll starts immediately, one pod at a
time; `specStatus` returns to `Valid` and database changes are allowed again.

## "Total shards count exceeds amount of total shards permitted by license"

**Symptom.** Creating a new REDB is denied at admission with this message.

**Cause.** Every shard counts against the license, including replicas and every
Active-Active copy. The cluster was already at its limit.

**Fix.** Check `oc get rec` (`SHARDS used/permitted`) before planning a new
database. For role/ACL testing you do not need a new database: scope the role
to an existing internal database with `kind: bdb` and its name.

## Replica `ERROR: timed out` during the REC roll

**Symptom.** `rladmin status` shows a replica `ERROR: timed out`, memory `N/A`,
while its pod is `ContainerCreating`.

**Cause.** Expected — the pod cannot answer while it is being recreated.

**Fix.** None, if it clears when the pod is `2/2`. Stop and investigate only if
a **primary/master** shows `ERROR: timed out`, or a timed-out shard persists
minutes after the pod is ready.

## `OK, OLD REDIS VERSION` right after a pod rejoins

**Symptom.** A replica on the freshly rolled pod shows this.

**Cause.** Expected. The REC image moved; the **database** version has not. The
replica catches up and returns to `OK` on its own.

**Fix.** None. Do not "fix" it by touching the database version — that is a
separate, later step.

## REAADB shows `active-change-pending` on one site

**Symptom.** After applying `globalConfigurations.redisVersion` on one site,
that site shows `active-change-pending` while the other site is already on the
new version.

**Cause.** Expected propagation between participating clusters.

**Fix.** Wait. Accept when both sites are `active` and `REDIS_VERSION` matches
(check with `redis-cli -p <port> INFO server`, not `oc get reaadb` — the CR
does not show the running version).

## Role CR created, but "referenced database not found - skipping"

**Symptom.** Operator log repeats `RedisEnterpriseDatabase X, referenced by
RedisEnterpriseRole Y, not found - skipping`; the role has a uid but no
database attached.

**Cause.** The scope points at a database that does not exist yet (or a typo).
The operator retries on its own.

**Fix.** If the database is simply later in the pipeline, this is fine — the
role attaches when the database appears. If the name is wrong, fix the scope.
For Active-Active databases use `kind: bdb`, not the REAADB object name.

## `role_uids validation failed` when posting an LDAP mapping

**Symptom.** `POST /v1/ldap_mappings` returns
`{"description":"role_uids validation failed: property \"role_uids\" is missing"}`.

**Cause.** The payload used a role name (`"role": "..."`). The 8.2 API requires
numeric uids.

**Fix.** Resolve the role to its uid first (`status.uid` on the CR, or match
the name in `GET /v1/roles` — CRD roles are `role#<ns>#<name>` /
`clusterrole#<ns>#<name>`), then post `role_uids: [<n>]`. The script in
[examples/ldap-mapping/](../examples/ldap-mapping/) does this resolution every
run.

## Transient 400s from the cluster API mid-roll

**Symptom.** Operator log shows API call failures (e.g. a `PUT` returning 400
`invalid_schema`) while some pods are still on the old image.

**Cause.** Mixed-version window: the new operator speaks to pods that have not
rolled yet.

**Fix.** Watch only. These clear as the roll completes. Treat them as a problem
only if they persist after every pod is on the new image and the REC is
`Running`.

## The golden rule

When anything above looks wrong mid-upgrade: **stop moving forward, do not
compensate with a second change.** Read the operator log
(`oc logs -n redis-ent -l name=redis-enterprise-operator`), confirm the other
site is still serving, and fix the one thing that is actually stuck.
