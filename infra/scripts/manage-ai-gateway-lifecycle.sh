#!/usr/bin/env bash
set -euo pipefail

AI_GATEWAY_API_VERSION="2025-09-01-preview"

poll_seconds="${APIM_LIFECYCLE_POLL_SECONDS:-10}"
identity_settle_seconds="${APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS:-180}"
operation_timeout_seconds="${APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS:-900}"

fail() {
  echo "AI Gateway lifecycle error: $*" >&2
  exit 1
}

REST_BODY=""
rest_get() {
  local uri="$1"
  local query="${2:-}"
  local output="${3:-json}"
  local error_text
  local -a args=(rest --method get --uri "$uri" -o "$output")

  if [ -n "$query" ]; then
    args+=(--query "$query")
  fi

  if REST_BODY="$(az "${args[@]}" 2>&1)"; then
    return 0
  fi

  error_text="$REST_BODY"
  if printf '%s' "$error_text" | grep -Eqi '(^ERROR:[[:space:]]*(\((NotFound|ResourceNotFound)\)|(Not Found|NotFound|ResourceNotFound)([[:space:]:({]|$))|"code"[[:space:]]*:[[:space:]]*"(NotFound|ResourceNotFound)"|"status(Code)?"[[:space:]]*:[[:space:]]*404)'; then
    REST_BODY=""
    return 1
  fi

  [ -z "$error_text" ] || printf '%s\n' "$error_text" >&2
  fail "Azure REST GET failed for $uri."
}

mode="${1:-}"
case "$mode" in
  prepare|cleanup) ;;
  *)
    echo "Usage: $0 prepare|cleanup" >&2
    exit 2
    ;;
esac

azd_value() {
  azd env get-value "$1" 2>/dev/null || true
}

first_value() {
  for value in "$@"; do
    if [ -n "$value" ] && [ "$value" != "null" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
}

discover_failed_gateway() {
  python3 - "$environment_name" "$subscription_id" "$resource_group" "$gateway_name" <<'PY'
import json
import re
import subprocess
import sys

environment, subscription, expected_group, expected_name = sys.argv[1:]
group_pattern = re.compile(r"rg-" + re.escape(environment.lower()) + r"-([a-z0-9]{8})-gateway", re.I)
resource_pattern = re.compile(
    r"/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.(ApiManagement/aigateways|Resources/deployments)/([^/]+)",
    re.I,
)
candidates = {}
visited = set()

def azure(*arguments):
    result = subprocess.run(["az", *arguments, "--subscription", subscription, "-o", "json"], stdout=subprocess.PIPE, text=True)
    if result.returncode:
        sys.exit(result.returncode)
    return json.loads(result.stdout)

def inspect(operations, depth):
    for operation in operations:
        properties = operation.get("properties", {})
        if properties.get("provisioningState") != "Failed":
            continue
        target = properties.get("targetResource") or {}
        match = resource_pattern.fullmatch(target.get("id", ""))
        if not match or match[1].lower() != subscription.lower():
            continue
        group, resource_type, name = match.group(2, 3, 4)
        group_match = group_pattern.fullmatch(group)
        if expected_group:
            if group.lower() != expected_group.lower():
                continue
        elif not group_match:
            continue
        kind = target.get("resourceType", "").lower()
        if kind == "microsoft.resources/deployments" and resource_type.lower() == "resources/deployments":
            key = target["id"].lower()
            if key not in visited:
                if depth >= 3 or len(visited) >= 30:
                    raise ValueError("failed deployment discovery exceeded its safe traversal limit")
                visited.add(key)
                inspect(azure("deployment", "operation", "group", "list", "--resource-group", group, "--name", name), depth + 1)
        elif kind == "microsoft.apimanagement/aigateways" and resource_type.lower() == "apimanagement/aigateways":
            if not re.search(r"\b(FailedIdentityOperation|ActivationFailed)\b", json.dumps(properties.get("statusMessage")), re.I):
                continue
            if expected_name:
                if name.lower() != expected_name.lower():
                    continue
            elif not group_match or name.lower() != "aigw-" + group_match[1].lower():
                continue
            candidates[target["id"].lower()] = (name, group)

deployments = azure("deployment", "sub", "list", "--query",
    "reverse(sort_by([?properties.provisioningState=='Failed'], &properties.timestamp))[:10]")
for deployment in deployments:
    if deployment.get("properties", {}).get("provisioningState") == "Failed":
        inspect(azure("deployment", "operation", "sub", "list", "--name", deployment["name"]), 0)
if len(candidates) > 1:
    raise ValueError("multiple AI Gateways found in failed deployments; set AI_GATEWAY_NAME and AI_GATEWAY_RESOURCE_GROUP")
for name, group in candidates.values():
    metadata = azure("group", "show", "--name", group)
    if metadata.get("tags", {}).get("azd-env-name") != environment:
        raise ValueError("refusing failed deployment resource group tagged for another or missing azd environment")
    print(name + "\t" + group)
PY
}

environment_name="$(first_value "${AZURE_ENV_NAME:-}" "$(azd_value AZURE_ENV_NAME)")"
[ -n "$environment_name" ] || fail "AZURE_ENV_NAME is required."

subscription_id="$(first_value \
  "${AZURE_SUBSCRIPTION_ID:-}" \
  "$(azd_value AZURE_SUBSCRIPTION_ID)" \
  "$(az account show --query id -o tsv 2>/dev/null || true)")"
[ -n "$subscription_id" ] || fail "AZURE_SUBSCRIPTION_ID is required."

resource_group="$(first_value \
  "${AI_GATEWAY_RESOURCE_GROUP:-}" \
  "$(azd_value AI_GATEWAY_RESOURCE_GROUP)")"
gateway_name="$(first_value \
  "${AI_GATEWAY_NAME:-}" \
  "$(azd_value AI_GATEWAY_NAME)")"

if [ -z "$resource_group" ] || [ -z "$gateway_name" ]; then
  candidates="$(az resource list \
    --subscription "$subscription_id" \
    --resource-type Microsoft.ApiManagement/aigateways \
    --query "[?tags.\"azd-env-name\"=='${environment_name}' && sku.name=='Consumption'].[name,resourceGroup]" \
    -o tsv)"
  candidate_count="$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$candidate_count" -eq 0 ]; then
    candidates="$(discover_failed_gateway)" || fail "failed deployment discovery could not establish ownership."
    if [ -z "$candidates" ]; then
      echo "No environment-owned AI Gateway requires lifecycle cleanup."
      exit 0
    fi
    candidate_count=1
  fi
  [ "$candidate_count" -eq 1 ] ||
    fail "multiple AI Gateways are tagged azd-env-name=${environment_name}; set AI_GATEWAY_NAME and AI_GATEWAY_RESOURCE_GROUP."
  IFS=$'\t' read -r gateway_name resource_group <<< "$candidates"
fi

resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/aigateways/${gateway_name}"
resource_uri="https://management.azure.com${resource_id}?api-version=${AI_GATEWAY_API_VERSION}"

if rest_get "$resource_uri"; then
  live_json="$REST_BODY"
  sku="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sku"]["name"])')"
  owner="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tags", {}).get("azd-env-name", ""))')"
  state="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["properties"].get("provisioningState", ""))')"
  [ "$sku" = "Consumption" ] || fail "refusing resource with SKU ${sku:-unknown}."
  [ "$owner" = "$environment_name" ] || fail "refusing resource tagged for azd environment ${owner:-missing}."

  if [ "$mode" = "prepare" ]; then
    case "$state" in
      Succeeded)
        echo "Preserving healthy environment-owned AI Gateway ${resource_group}/${gateway_name}."
        exit 0
        ;;
      Failed) ;;
      Deleting) ;;
      *) fail "the environment-owned AI Gateway is in nonterminal state ${state:-unknown}; wait for Azure to finish or run azd down." ;;
    esac
  fi

  if [ "$state" != "Deleting" ]; then
    echo "Deleting environment-owned AI Gateway ${resource_group}/${gateway_name}."
    az rest --method delete --uri "$resource_uri" --headers 'If-Match=*' -o none
  fi
fi

started_at="$(date +%s)"
quiet_started_at=""
while true; do
  now="$(date +%s)"
  if [ $((now - started_at)) -ge "$operation_timeout_seconds" ]; then
    fail "cleanup did not settle within ${operation_timeout_seconds}s. Wait, then rerun azd provision."
  fi

  if rest_get "$resource_uri"; then
    quiet_started_at=""
    echo "Waiting for AI Gateway deletion."
    sleep "$poll_seconds"
    continue
  fi

  if [ -z "$quiet_started_at" ]; then
    quiet_started_at="$now"
  fi
  quiet_elapsed=$((now - quiet_started_at))
  if [ "$quiet_elapsed" -ge "$identity_settle_seconds" ]; then
    echo "AI Gateway deletion and ${identity_settle_seconds}s identity settle window completed."
    exit 0
  fi

  echo "Waiting for managed-identity cleanup (${quiet_elapsed}/${identity_settle_seconds}s quiet)."
  sleep "$poll_seconds"
done
