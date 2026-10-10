# 03 — LDAP and RBAC: from the basics to mappings as code

Starts from zero LDAP knowledge and ends at an idempotent Job that replaces
manual work in the Cluster Manager UI.

## LDAP in five minutes

LDAP is a directory: a central store of users and groups (Active Directory is
the common one). The application never stores passwords. At login it asks the
directory two things — *who is this?* and *which groups are they in?* — and
derives access from the groups.

| Term | Meaning | Example |
| --- | --- | --- |
| DN | Full address of an entry | `cn=app-readers,ou=groups,dc=example,dc=com` |
| Bind | LDAP's word for "log in" | — |
| Bind DN | Service account the app uses to search | `svc-redis@example.com` |
| Search base / filter | Where and how to find the user | `ou=users,dc=example,dc=com`, `(cn=%u)` |
| LDAPS | TLS from the first byte, port 636 | production default |

Every LDAP login runs the same four steps:

1. User types username + password.
2. App binds **as the service account** and searches for the user → their DN
   (the *authentication query*).
3. App binds again **as the user's DN with the typed password**. Success means
   the password is right. The app never sees it.
4. App reads the user's group memberships (the *authorization query*).

Everything after step 4 is the app's own mapping from groups to permissions.

## How Redis Enterprise runs it

The connection lives in the REC CRD, `spec.ldap` (same schema on 8.0 and 8.2):

| Field | Serves | What it sets |
| --- | --- | --- |
| `servers`, `protocol: LDAPS` | transport | Directory endpoints |
| `caCertificateSecretName` | transport | CA for the LDAPS certificate |
| `bindCredentialsSecretName` | step 2 | Service account (secret keys `dn`, `password`) |
| `authenticationQuery` | step 2 | Base/filter/scope, or a DN `template` |
| `authorizationQuery` | step 4 | Group membership: attribute or search (`%D` = user DN) |
| `enabledForControlPlane` | — | LDAP into Cluster Manager UI + REST API |
| `enabledForDataPlane` | — | LDAP into databases (Redis clients) |
| `cacheTTLSeconds` | — | Group-cache lifetime |

Groups become access through three objects:

```
LDAP group DN --> LDAP mapping (/v1/ldap_mappings) --> Role --> ACL + scope
```

- The **mapping** joins one group DN to role uids.
- The **role** = management permission (UI/API) + data ACL (Redis commands) +
  scope (all databases, or selected ones). The two halves are independent.
- A user in several mapped groups gets all of their roles.

## Upgrading 8.0 → 8.2 with LDAP: what keeps working, what needs attention

**Keeps working**

- The `spec.ldap` connection — unchanged schema, and it is cluster config, so
  it survives the REC roll.
- Existing group→role mappings and API/UI-created roles, users, ACLs. They keep
  their uids. The new CRDs do not adopt them.
- LDAP sign-in during the roll — pods roll one at a time.

**Needs attention**

- Database changes are frozen between operator approval and REC roll
  (`REC is frozen`). Plan for that gap.
- `digestHash` + `autoUpgradeRedisEnterprise: true` is rejected on 8.2 — fix
  the REC spec when the operator moves.
- **The mapping payload shape**: `POST /v1/ldap_mappings` requires
  `role_uids` (list of numeric role uids). A role *name* string is rejected
  (`role_uids validation failed`). Audit any 8.0-era automation that posts
  mappings.

**New in 8.2 you can use**

- Declare ACLs, users, and roles as YAML (see
  [02-operator-8.2-crds.md](02-operator-8.2-crds.md)).
- Selector-scoped roles solve the ordering problem: the cluster chart ships the
  role once; databases deployed later with the matching label join it
  automatically.
- Map LDAP groups to CRD-managed roles.

## The uid bridge (how a CRD role meets an LDAP mapping)

A mapping references roles by **cluster-side numeric uid**, not by name. When
the operator reconciles a role CR, it writes that uid to the CR's `status.uid`:

```bash
oc get rerole app-readers-role -n redis-ent -o jsonpath='{.status.uid}'
# -> 4
```

That same role exists in the cluster as uid 4, named
`role#redis-ent#app-readers-role`. So the mapping is:

```json
POST /v1/ldap_mappings
{"name": "app-readers",
 "dn": "cn=redis-app-readers,ou=groups,dc=example,dc=com",
 "role_uids": [4]}
```

Verified end to end: CR created → `status.uid` appeared → role visible in
`GET /v1/roles` → mapping accepted and listed. (A real AD login through the
mapping was not part of the lab — no AD there.)

Caveat: if a role CR is deleted and recreated it gets a **new uid**, and a
hardcoded mapping silently points at nothing. Resolve uids fresh every run —
which is exactly what the script below does.

## Mappings as code: the Job

[examples/ldap-mapping/](../examples/ldap-mapping/) contains a tested,
idempotent applier:

| File | Purpose |
| --- | --- |
| `ldap-role-mapping.sh` | Creates missing mappings, updates drifted ones, skips matching ones, exits non-zero on unknown roles. `PRUNE=true` also deletes mappings not in the file. |
| `mappings.tsv` | Desired state: name, group DN, role refs (`rerole/<cr>`, `recrole/<cr>`, `role:<internal>`, `uid:<n>`). |
| `job-ldap-role-mapping.yaml` | Runs the script in-cluster. Credentials from the REC credential secret via env; no RBAC (it only calls the Redis API); image is the REC node image (already has bash, curl, python3). |

Tested behaviour: create → rerun reports unchanged → hand-edited DN corrected
back to the file → unknown role ref fails that line only → prune deletes
orphans only.

```bash
oc -n redis-ent create configmap ldap-role-mapping \
  --from-file=ldap-role-mapping.sh=ldap-role-mapping.sh \
  --from-file=mappings.tsv=mappings.tsv \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f job-ldap-role-mapping.yaml
oc logs -n redis-ent job/ldap-role-mapping
```

Keep `PRUNE=false` until the file is the declared source of truth for **every**
mapping.

## What LDAP auth does not do

- **No local users.** LDAP users have no Redis password; if the directory is
  down they cannot log in. Keep one local admin (or a `RedisEnterpriseUser`)
  as break-glass.
- **No sync.** Nothing is copied from AD. Mappings are evaluated at login, so
  AD-side revocation takes effect at next login (after `cacheTTLSeconds`).
- **No session rewiring.** Role and mapping changes apply to the *next* login.

## When it fails

| Symptom | Check first |
| --- | --- |
| All LDAP logins fail | Bind-DN credentials and CA cert in `spec.ldap` |
| One user fails | Their DN vs `authenticationQuery` base/filter |
| Login works, no permissions | Group DN in the mapping must match exactly — DNs are literal strings |
| Permissions lag a change | `cacheTTLSeconds` |
