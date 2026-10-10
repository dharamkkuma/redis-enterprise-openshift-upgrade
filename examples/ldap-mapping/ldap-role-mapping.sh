#!/usr/bin/env bash
# ldap-role-mapping.sh
#
# Idempotent LDAP group -> Redis Enterprise role mappings.
# Replaces manual work in the Cluster Manager UI.
#
# Safe to re-run: creates what is missing, updates what drifted,
# leaves what already matches. Nothing is deleted unless PRUNE=true.
#
# Runs anywhere that can reach the cluster API on 9443 and has
# bash, curl and python3. The Redis Enterprise node image has all three,
# which is what the Job in this directory uses.
#
# Required env:
#   REC_USERNAME   cluster admin user   (REC credential secret, key "username")
#   REC_PASSWORD   cluster admin password (REC credential secret, key "password")
#
# Optional env:
#   REC_API_URL        default https://rec-a:9443 (in-cluster service DNS)
#   REC_NAMESPACE      default redis-ent. Used to build the internal role
#                      name for CRD-managed roles: role#<ns>#<cr-name>.
#   MAPPINGS_FILE      default /work/mappings.tsv
#   PRUNE              default false. true = delete mappings that are not
#                      in the file. Leave false until the file is the
#                      declared source of truth.
#   CA_FILE            PEM for the API TLS cert. Default: -k (lab, self-signed).
#   API_WAIT_SECONDS   default 300. How long to wait for the API to answer.
#
# Mappings file: one mapping per line, TAB-separated, # comments allowed:
#   <mapping-name> <TAB> <ldap-group-dn> <TAB> <role-ref>[,<role-ref>...]
#
# Role refs:
#   rerole/<cr-name>    RedisEnterpriseRole CR        -> role#<ns>#<cr-name>
#   recrole/<cr-name>   RedisEnterpriseClusterRole CR -> clusterrole#<ns>#<cr-name>
#   role:<name>         internal role name, as shown by GET /v1/roles
#   uid:<n>             internal role uid, already known
#
# The uid is resolved through the Redis Enterprise API. No oc or kubectl
# is needed at runtime, so the Job needs no RBAC.

set -euo pipefail

REC_API_URL="${REC_API_URL:-https://rec-a:9443}"
REC_NAMESPACE="${REC_NAMESPACE:-redis-ent}"
MAPPINGS_FILE="${MAPPINGS_FILE:-/work/mappings.tsv}"
PRUNE="${PRUNE:-false}"
CA_FILE="${CA_FILE:-}"
API_WAIT_SECONDS="${API_WAIT_SECONDS:-300}"

: "${REC_USERNAME:?REC_USERNAME is required (REC credential secret, key username)}"
: "${REC_PASSWORD:?REC_PASSWORD is required (REC credential secret, key password)}"

CURL_TLS=(-sk)
if [[ -n "$CA_FILE" ]]; then
  CURL_TLS=(--cacert "$CA_FILE")
fi

api() { # api METHOD PATH [JSON-BODY]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS "${CURL_TLS[@]}" -u "$REC_USERNAME:$REC_PASSWORD"
              -X "$method" "$REC_API_URL$path")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  curl "${args[@]}"
}

wait_for_api() {
  local waited=0
  until api GET /v1/cluster >/dev/null 2>&1; do
    if (( waited >= API_WAIT_SECONDS )); then
      echo "FATAL: $REC_API_URL did not answer within ${API_WAIT_SECONDS}s" >&2
      exit 1
    fi
    sleep 5; waited=$((waited + 5))
  done
}

# Resolve one role ref to a numeric uid, using the roles list fetched once.
ROLES_JSON=""
resolve_role_uid() { # resolve_role_uid REF -> prints uid
  local ref="$1" internal
  case "$ref" in
    uid:*)     echo "${ref#uid:}"; return 0 ;;
    rerole/*)  internal="role#${REC_NAMESPACE}#${ref#rerole/}" ;;
    recrole/*) internal="clusterrole#${REC_NAMESPACE}#${ref#recrole/}" ;;
    role:*)    internal="${ref#role:}" ;;
    *)         internal="$ref" ;;
  esac
  printf '%s' "$ROLES_JSON" | python3 -c '
import json, sys
name = sys.argv[1]
roles = json.load(sys.stdin)
if isinstance(roles, dict):
    roles = roles.get("roles") or roles.get("items") or []
for r in roles:
    if r.get("name") == name:
        print(r["uid"]); sys.exit(0)
sys.exit(1)
' "$internal" || {
    echo "ERROR: role not found in cluster: $ref (looked for '$internal' in GET /v1/roles)" >&2
    return 1
  }
}

build_body() { # build_body NAME DN UIDS_CSV [EMAIL] [EMAIL_ALERTS]
  python3 -c '
import json, sys
name, dn, uids_csv = sys.argv[1], sys.argv[2], sys.argv[3]
body = {
    "name": name,
    "dn": dn,
    "role_uids": sorted(int(u) for u in uids_csv.split(",") if u.strip()),
}
if len(sys.argv) > 5 and sys.argv[5]:
    body["email"] = sys.argv[4]
    body["email_alerts"] = sys.argv[5] == "true"
print(json.dumps(body))
' "$@"
}

# Current state of one existing mapping, as: uid<TAB>dn<TAB>uids_csv<TAB>email<TAB>email_alerts
mapping_state() { # mapping_state NAME  (reads MAPPINGS_JSON)
  printf '%s' "$MAPPINGS_JSON" | python3 -c '
import json, sys
name = sys.argv[1]
maps = json.load(sys.stdin)
if isinstance(maps, dict):
    maps = maps.get("ldap_mappings") or maps.get("items") or []
for m in maps:
    if m.get("name") == name:
        uids = ",".join(str(u) for u in sorted(m.get("role_uids") or []))
        email = m.get("email") or ""
        alerts = "true" if m.get("email_alerts", True) else "false"
        print("%s\t%s\t%s\t%s\t%s" % (m.get("uid"), m.get("dn"), uids, email, alerts))
        sys.exit(0)
sys.exit(1)
' "$1"
}

main() {
  [[ -f "$MAPPINGS_FILE" ]] || { echo "FATAL: $MAPPINGS_FILE not found" >&2; exit 1; }

  wait_for_api
  echo "API $REC_API_URL reachable. Reading roles and existing mappings."

  ROLES_JSON="$(api GET /v1/roles)"
  MAPPINGS_JSON="$(api GET /v1/ldap_mappings)"

  local created=0 updated=0 unchanged=0 deleted=0 failed=0
  local -a seen_names=()

  while IFS=$'\t' read -r name dn refs || [[ -n "${name:-}" ]]; do
    [[ -z "${name// }" || "$name" == \#* ]] && continue
    seen_names+=("$name")

    # resolve all role refs to uids
    local uids="" ref uid
    local rc=0
    IFS=',' read -ra ref_list <<< "$refs"
    for ref in "${ref_list[@]}"; do
      ref="${ref// /}"
      [[ -z "$ref" ]] && continue
      if ! uid="$(resolve_role_uid "$ref")"; then rc=1; break; fi
      uids="${uids:+$uids,}$uid"
    done
    if (( rc != 0 )) || [[ -z "$uids" ]]; then
      echo "[fail] $name: unresolved role ref, skipped"
      failed=$((failed + 1)); continue
    fi

    local desired_body
    if existing="$(mapping_state "$name")"; then
      IFS=$'\t' read -r ex_uid ex_dn ex_uids ex_email ex_alerts <<< "$existing"
      if [[ "$ex_dn" == "$dn" && "$ex_uids" == "$uids" ]]; then
        echo "[ok]   $name unchanged (uid $ex_uid, roles $uids)"
        unchanged=$((unchanged + 1)); continue
      fi
      desired_body="$(build_body "$name" "$dn" "$uids" "$ex_email" "$ex_alerts")"
      if api PUT "/v1/ldap_mappings/$ex_uid" "$desired_body" >/dev/null; then
        echo "[upd]  $name (uid $ex_uid) dn='$dn' roles $ex_uids -> $uids"
        updated=$((updated + 1))
      else
        echo "[fail] $name: PUT /v1/ldap_mappings/$ex_uid failed"
        failed=$((failed + 1))
      fi
    else
      desired_body="$(build_body "$name" "$dn" "$uids")"
      if api POST /v1/ldap_mappings "$desired_body" >/dev/null; then
        echo "[new]  $name -> dn='$dn' roles $uids"
        created=$((created + 1))
      else
        echo "[fail] $name: POST /v1/ldap_mappings failed"
        failed=$((failed + 1))
      fi
    fi
  done < "$MAPPINGS_FILE"

  if [[ "$PRUNE" == "true" ]]; then
    # delete mappings whose name is not in the file
    while IFS=$'\t' read -r m_uid m_name; do
      [[ -z "$m_uid" ]] && continue
      local found=false s
      for s in "${seen_names[@]:-}"; do [[ "$s" == "$m_name" ]] && found=true && break; done
      if [[ "$found" == false ]]; then
        if api DELETE "/v1/ldap_mappings/$m_uid" >/dev/null; then
          echo "[del]  $m_name (uid $m_uid) not in file, PRUNE=true"
          deleted=$((deleted + 1))
        else
          echo "[fail] $m_name: DELETE /v1/ldap_mappings/$m_uid failed"
          failed=$((failed + 1))
        fi
      fi
    done < <(printf '%s' "$MAPPINGS_JSON" | python3 -c '
import json, sys
maps = json.load(sys.stdin)
if isinstance(maps, dict):
    maps = maps.get("ldap_mappings") or maps.get("items") or []
for m in maps:
    print("%s\t%s" % (m.get("uid"), m.get("name")))
')
  fi

  echo "---"
  echo "created=$created updated=$updated unchanged=$unchanged deleted=$deleted failed=$failed"
  (( failed == 0 ))
}

main "$@"
