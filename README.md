# Redis Enterprise upgrade on OpenShift — a tested field guide

How to upgrade Redis Enterprise on OpenShift without surprises: the OperatorHub
channel flow, the cluster image roll, database versions, the RBAC CRDs added in
operator 8.2, and LDAP group mapping as code.

Everything here was exercised on live OpenShift clusters, not read from
documentation alone. Where something is product behaviour rather than a tested
result, the text says so.

## Who this is for

Platform engineers running Redis Enterprise clusters (RECs) through the Redis
Enterprise Operator on OpenShift, especially with Operator Lifecycle Manager
(OLM) update approval set to **Manual** and upgrades driven from the console.

## How to read this repo

Read in this order. Each doc stands alone, but the mental model in doc 01 makes
the rest obvious.

| Order | Document | Read it when | What you get |
| --- | --- | --- | --- |
| 1 | [docs/01-upgrade-guide.md](docs/01-upgrade-guide.md) | Before any upgrade window | The three things an upgrade moves, the OLM channel mechanics, the automatic vs manual REC roll, database version upgrades |
| 2 | [docs/02-operator-8.2-crds.md](docs/02-operator-8.2-crds.md) | Planning an 8.2 upgrade, or designing RBAC | The six CRDs 8.2 adds (users, ACLs, roles, bindings), what each does, what changed from 8.0 |
| 3 | [docs/03-ldap-and-rbac.md](docs/03-ldap-and-rbac.md) | You use LDAP/AD, or need roles at scale | LDAP from basics to login flow, what survives an 8.0 → 8.2 upgrade, mapping groups to roles with a Job instead of the UI |
| 4 | [docs/04-troubleshooting.md](docs/04-troubleshooting.md) | Something is stuck | Failure modes actually observed, with the cause and the fix for each |

## The 60-second mental model

An upgrade on OpenShift moves **three separate versions**, in this order:

1. **Operator** — the OpenShift controller from OperatorHub. Approving its
   InstallPlan changes nothing else by itself.
2. **REC (Redis Enterprise cluster)** — the Redis Software image. Shipped
   *bundled with a set of database versions*. Read the release notes to know
   what a release delivers before you take it.
3. **Database** — each database's Redis version. The REC roll does not move it.
   Each database is upgraded on its own, after the cluster image is done.

Most upgrade surprises come from treating these as one thing.

## Tested on

| Component | From | To |
| --- | --- | --- |
| Redis Enterprise Operator | 8.0.18-14.2 / 8.0.20-27.1 | 8.2.0-18.0 |
| REC image | 8.0.18-36.14 | 8.2.0-78.18 |
| Database | Redis 8.6.2 (Active-Active) | unchanged during REC roll |
| OpenShift | 4.19 | — |

Two clusters in an Active-Active pair (`RedisEnterpriseActiveActiveDatabase`),
one upgraded at a time.

## Repository layout

```
docs/                 the four guides, in reading order
examples/
  rec/                upgradeSpec automatic and manual REC specs
  reaadb/             Active-Active database with redisVersion
  crds-8.2/           one minimal YAML per new 8.2 CRD
  ldap-mapping/       idempotent LDAP group→role mapping script + Job
```

Every YAML is minimal on purpose: apply it, watch what the operator does, then
read the matching doc for the explanation.

## A note on provenance

The procedures were validated on a lab Active-Active pair. Cluster names,
domains, and secrets from that environment have been replaced with generic
ones. Versions, commands, API payloads, and error messages are real.

Not affiliated with or endorsed by Redis. Check the release notes for your
exact operator build before any window — they are the authoritative source.
