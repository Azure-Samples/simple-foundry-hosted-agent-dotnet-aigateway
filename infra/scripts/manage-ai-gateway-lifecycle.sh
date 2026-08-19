#!/usr/bin/env bash
set -euo pipefail

AI_GATEWAY_API_VERSION="2025-09-01-preview"
DELETED_SERVICE_API_VERSION="2024-05-01"
DEFAULT_AI_GATEWAY_LOCATION="eastus2"

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
  local error_file
  local error_text
  local -a args=(rest --method get --uri "$uri" -o "$output")

  if [ -n "$query" ]; then
    args+=(--query "$query")
  fi

  error_file="$(mktemp)"
  if REST_BODY="$(az "${args[@]}" 2>"$error_file")"; then
    rm -f "$error_file"
    return 0
  fi

  error_text="$(<"$error_file")"
  rm -f "$error_file"
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

normalize_location() {
  printf '%s' "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]'
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
gateway_location="$(normalize_location "$(first_value \
  "${AI_GATEWAY_LOCATION:-}" \
  "$(azd_value AI_GATEWAY_LOCATION)" \
  "$DEFAULT_AI_GATEWAY_LOCATION")")"

if [ -z "$resource_group" ] || [ -z "$gateway_name" ]; then
  candidates="$(az resource list \
    --subscription "$subscription_id" \
    --resource-type Microsoft.ApiManagement/service \
    --query "[?tags.\"azd-env-name\"=='${environment_name}' && sku.name=='AIGateway'].[name,resourceGroup,location]" \
    -o tsv)"
  candidate_count="$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$candidate_count" -eq 0 ]; then
    echo "No environment-owned AI Gateway requires lifecycle cleanup."
    exit 0
  fi
  [ "$candidate_count" -eq 1 ] ||
    fail "multiple AIGateway services are tagged azd-env-name=${environment_name}; set AI_GATEWAY_NAME and AI_GATEWAY_RESOURCE_GROUP."
  IFS=$'\t' read -r gateway_name resource_group gateway_location <<< "$candidates"
  gateway_location="$(normalize_location "$gateway_location")"
fi

resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${gateway_name}"
resource_uri="https://management.azure.com${resource_id}?api-version=${AI_GATEWAY_API_VERSION}"
deleted_uri="https://management.azure.com/subscriptions/${subscription_id}/providers/Microsoft.ApiManagement/locations/${gateway_location}/deletedservices/${gateway_name}?api-version=${DELETED_SERVICE_API_VERSION}"

if rest_get "$resource_uri"; then
  live_json="$REST_BODY"
  sku="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sku"]["name"])')"
  owner="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tags", {}).get("azd-env-name", ""))')"
  state="$(printf '%s' "$live_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["properties"].get("provisioningState", ""))')"
  [ "$sku" = "AIGateway" ] || fail "refusing resource with SKU ${sku:-unknown}."
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

  deleted_service_id=""
  if rest_get "$deleted_uri" properties.serviceId tsv; then
    deleted_service_id="$REST_BODY"
  fi
  if [ -n "$deleted_service_id" ]; then
    quiet_started_at=""
    if [ "$(printf '%s' "$deleted_service_id" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$resource_id" | tr '[:upper:]' '[:lower:]')" ]; then
      fail "refusing to purge soft-deleted AI Gateway because its serviceId does not match ${resource_id}."
    fi
    echo "Purging soft-deleted AI Gateway ${gateway_name} in ${gateway_location}."
    az rest --method delete --uri "$deleted_uri" -o none
    sleep "$poll_seconds"
    continue
  fi

  if [ -z "$quiet_started_at" ]; then
    quiet_started_at="$now"
  fi
  quiet_elapsed=$((now - quiet_started_at))
  if [ "$quiet_elapsed" -ge "$identity_settle_seconds" ]; then
    echo "AI Gateway deletion, soft-delete purge, and ${identity_settle_seconds}s identity settle window completed."
    exit 0
  fi

  echo "Waiting for managed-identity cleanup (${quiet_elapsed}/${identity_settle_seconds}s quiet)."
  sleep "$poll_seconds"
done
