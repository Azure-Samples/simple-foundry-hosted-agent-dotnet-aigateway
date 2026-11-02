#!/usr/bin/env bash
set -euo pipefail
umask 077

AI_GATEWAY_API_VERSION="2025-09-01-preview"
DEFAULT_AI_GATEWAY_LOCATION="eastus2"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

poll_initial_seconds="${APIM_LIFECYCLE_POLL_INITIAL_SECONDS:-5}"
poll_max_seconds="${APIM_LIFECYCLE_POLL_MAX_SECONDS:-30}"
identity_settle_seconds="${APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS:-180}"
operation_timeout_seconds="${APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS:-900}"
recent_deployment_limit="${APIM_LIFECYCLE_RECENT_DEPLOYMENT_LIMIT:-10}"

usage() {
  cat >&2 <<EOF
Usage: $0 prepare|cleanup

prepare  Safely recovers only an environment-owned terminal-Failed AI Gateway
         and waits for managed-identity cleanup.
cleanup  Completes an explicit azd down/recovery action and waits for the same
         bounded managed-identity settle window.

Timing overrides:
  APIM_LIFECYCLE_POLL_INITIAL_SECONDS
  APIM_LIFECYCLE_POLL_MAX_SECONDS
  APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS
  APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS
  APIM_LIFECYCLE_RECENT_DEPLOYMENT_LIMIT
EOF
}

fail() {
  echo "AI Gateway lifecycle error: $*" >&2
  exit 1
}

validate_nonnegative_integer() {
  case "$2" in
    ''|*[!0-9]*) fail "$1 must be a nonnegative integer." ;;
  esac
}

for setting in \
  "APIM_LIFECYCLE_POLL_INITIAL_SECONDS:$poll_initial_seconds" \
  "APIM_LIFECYCLE_POLL_MAX_SECONDS:$poll_max_seconds" \
  "APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS:$identity_settle_seconds" \
  "APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS:$operation_timeout_seconds" \
  "APIM_LIFECYCLE_RECENT_DEPLOYMENT_LIMIT:$recent_deployment_limit"; do
  validate_nonnegative_integer "${setting%%:*}" "${setting#*:}"
done

mode="${1:-}"
case "$mode" in
  prepare|cleanup) ;;
  *) usage; exit 2 ;;
esac

azd_value() {
  local value
  if value="$(azd env get-value "$1" 2>/dev/null)"; then
    printf '%s' "$value"
  fi
}

first_value() {
  local value
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

now_epoch() {
  date +%s
}

sleep_for() {
  if [ "$1" -gt 0 ]; then
    sleep "$1"
  fi
}

next_delay() {
  local delay="$1"
  if [ "$delay" -eq 0 ] || [ "$delay" -ge "$poll_max_seconds" ]; then
    printf '%s' "$poll_max_seconds"
  elif [ $((delay * 2)) -gt "$poll_max_seconds" ]; then
    printf '%s' "$poll_max_seconds"
  else
    printf '%s' $((delay * 2))
  fi
}

marker_value() {
  local key="$1"
  [ -f "$state_file" ] || return 0
  sed -n "s/^${key}=//p" "$state_file" | tail -n 1
}

safe_marker_value() {
  printf '%s' "$1" | tr -d '\r\n'
}

write_marker() {
  local marker_state="$1"
  local action_epoch="$2"
  local failure_id="$3"
  mkdir -p "$(dirname "$state_file")"
  {
    printf 'version=1\n'
    printf 'environment_name=%s\n' "$(safe_marker_value "$environment_name")"
    printf 'subscription_id=%s\n' "$(safe_marker_value "$subscription_id")"
    printf 'resource_group=%s\n' "$(safe_marker_value "$resource_group")"
    printf 'gateway_name=%s\n' "$(safe_marker_value "$gateway_name")"
    printf 'location=%s\n' "$(safe_marker_value "$gateway_location")"
    printf 'state=%s\n' "$(safe_marker_value "$marker_state")"
    printf 'action_epoch=%s\n' "$(safe_marker_value "$action_epoch")"
    printf 'failure_id=%s\n' "$(safe_marker_value "$failure_id")"
  } > "${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
}

is_not_found_error() {
  grep -Eiq '(^|[^0-9])404([^0-9]|$)|ResourceNotFound|NotFound' "$1"
}

rest_get() {
  local uri="$1"
  local query="${2:-}"
  local error_file
  local output
  local status=1
  local succeeded=false
  error_file="$(mktemp)"
  if [ -n "$query" ]; then
    if output="$(az rest --method get --uri "$uri" --query "$query" -o tsv 2>"$error_file")"; then
      succeeded=true
    else
      status=$?
    fi
  elif output="$(az rest --method get --uri "$uri" -o none 2>"$error_file")"; then
    succeeded=true
  else
    status=$?
  fi
  if [ "$succeeded" = true ]; then
    rm -f "$error_file"
    printf '%s' "$output"
    return 0
  fi
  if is_not_found_error "$error_file"; then
    rm -f "$error_file"
    return 4
  fi
  cat "$error_file" >&2
  rm -f "$error_file"
  return "${status:-1}"
}

rest_delete() {
  local uri="$1"
  local require_match="${2:-false}"
  local error_file
  local status
  error_file="$(mktemp)"
  if [ "$require_match" = true ]; then
    delete_args=(--method delete --uri "$uri" --headers 'If-Match=*' -o none)
  else
    delete_args=(--method delete --uri "$uri" -o none)
  fi
  if az rest "${delete_args[@]}" 2>"$error_file"; then
    rm -f "$error_file"
    return 0
  else
    status=$?
  fi
  if is_not_found_error "$error_file"; then
    rm -f "$error_file"
    return 0
  fi
  cat "$error_file" >&2
  rm -f "$error_file"
  return "$status"
}

validate_deterministic_shape() {
  local candidate_name="$1"
  local candidate_group="$2"
  local environment_label
  environment_label="$(printf '%s' "$environment_name" | tr '[:upper:]' '[:lower:]')"
  case "$candidate_name" in
    aigw-*) ;;
    *) return 1 ;;
  esac
  case "$(printf '%s' "$candidate_group" | tr '[:upper:]' '[:lower:]')" in
    "rg-${environment_label}-"*"-gateway") ;;
    *) return 1 ;;
  esac
}

discover_live_gateway() {
  local candidates
  local candidate_name
  local candidate_group
  local candidate_location
  local count=0
  local selected=""
  if ! candidates="$(az resource list \
    --subscription "$subscription_id" \
    --resource-type Microsoft.ApiManagement/aigateways \
    --query "[?tags.\"azd-env-name\"=='${environment_name}' && sku.name=='Premium'].[name,resourceGroup,location]" \
    -o tsv)"; then
    fail "could not discover AI Gateway resources for azd environment ${environment_name}."
  fi
  while IFS=$'\t' read -r candidate_name candidate_group candidate_location; do
    [ -n "$candidate_name" ] || continue
    if ! validate_deterministic_shape "$candidate_name" "$candidate_group"; then
      fail "refusing the tagged AI Gateway ${candidate_group}/${candidate_name} because it does not match the deterministic environment naming shape."
    fi
    count=$((count + 1))
    selected="${candidate_name}"$'\t'"${candidate_group}"$'\t'"${candidate_location}"
  done <<< "$candidates"
  if [ "$count" -gt 1 ]; then
    fail "found multiple AI Gateways tagged azd-env-name=${environment_name}; set AI_GATEWAY_NAME and AI_GATEWAY_RESOURCE_GROUP explicitly."
  fi
  if [ "$count" -eq 1 ]; then
    IFS=$'\t' read -r gateway_name resource_group gateway_location <<< "$selected"
    return 0
  fi
  return 1
}

find_recent_identity_failure() {
  local deployments
  local deployment_name
  local operation_targets
  local target_id
  local nested_targets
  local nested_target_id
  local target_subscription
  local target_group
  local target_provider
  local target_type
  local target_name
  local group_owner
  recent_failure_id=""
  if ! deployments="$(az deployment sub list \
    --subscription "$subscription_id" \
    --query "[?properties.provisioningState=='Failed'] | sort_by(@, &properties.timestamp) | reverse(@)[:${recent_deployment_limit}].name" \
    -o tsv 2>/dev/null)"; then
    fail "could not inspect recent subscription deployment failures for managed-identity recovery."
  fi
  while IFS= read -r deployment_name; do
    [ -n "$deployment_name" ] || continue
    operation_targets="$(az deployment operation sub list \
      --subscription "$subscription_id" \
      --name "$deployment_name" \
      --query "[?contains(to_string(properties.statusMessage), 'FailedIdentityOperation') || contains(to_string(properties.statusMessage), 'ActivationFailed')].properties.targetResource.id" \
      -o tsv 2>/dev/null || true)"
    while IFS= read -r target_id; do
      [ -n "$target_id" ] && [ "$target_id" != "null" ] || continue
      target_group="$(printf '%s' "$target_id" | cut -d/ -f5)"
      target_provider="$(printf '%s' "$target_id" | cut -d/ -f7)"
      target_type="$(printf '%s' "$target_id" | cut -d/ -f8)"
      target_name="$(printf '%s' "$target_id" | cut -d/ -f9)"
      if [ "$(printf '%s' "$target_provider" | tr '[:upper:]' '[:lower:]')" = "microsoft.resources" ] &&
        [ "$(printf '%s' "$target_type" | tr '[:upper:]' '[:lower:]')" = "deployments" ]; then
        nested_targets="$(az deployment operation group list \
          --subscription "$subscription_id" \
          --resource-group "$target_group" \
          --name "$target_name" \
          --query "[?contains(to_string(properties.statusMessage), 'FailedIdentityOperation') || contains(to_string(properties.statusMessage), 'ActivationFailed')].properties.targetResource.id" \
          -o tsv 2>/dev/null || true)"
        while IFS= read -r nested_target_id; do
          [ -n "$nested_target_id" ] && [ "$nested_target_id" != "null" ] || continue
          if adopt_failure_target "$nested_target_id" "${deployment_name}:${target_id}"; then
            return 0
          fi
        done <<< "$nested_targets"
      elif adopt_failure_target "$target_id" "$deployment_name"; then
        return 0
      fi
    done <<< "$operation_targets"
  done <<< "$deployments"
  return 1
}

adopt_failure_target() {
  local target_id="$1"
  local deployment_id="$2"
  local target_subscription
  local target_group
  local target_provider
  local target_type
  local target_name
  local group_owner
  target_subscription="$(printf '%s' "$target_id" | cut -d/ -f3)"
  target_group="$(printf '%s' "$target_id" | cut -d/ -f5)"
  target_provider="$(printf '%s' "$target_id" | cut -d/ -f7)"
  target_type="$(printf '%s' "$target_id" | cut -d/ -f8)"
  target_name="$(printf '%s' "$target_id" | cut -d/ -f9)"
  if [ "$(printf '%s' "$target_subscription" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$subscription_id" | tr '[:upper:]' '[:lower:]')" ] ||
    [ "$(printf '%s' "$target_provider" | tr '[:upper:]' '[:lower:]')" != "microsoft.apimanagement" ] ||
    [ "$(printf '%s' "$target_type" | tr '[:upper:]' '[:lower:]')" != "aigateways" ] ||
    ! validate_deterministic_shape "$target_name" "$target_group"; then
    return 1
  fi
  group_owner="$(az group show \
    --subscription "$subscription_id" \
    --name "$target_group" \
    --query "tags.\"azd-env-name\"" \
    -o tsv 2>/dev/null || true)"
  if [ -n "$group_owner" ] && [ "$group_owner" != "null" ] && [ "$group_owner" != "$environment_name" ]; then
    fail "refusing identity recovery for ${target_group}/${target_name}; its resource group is tagged for azd environment ${group_owner}."
  fi
  if [ "$group_owner" != "$environment_name" ]; then
    return 1
  fi
  gateway_name="$target_name"
  resource_group="$target_group"
  recent_failure_id="${deployment_id}:${target_id}"
  return 0
}

load_live_record() {
  local record
  local status
  if record="$(rest_get "$service_uri" "join('|', [to_string(properties.provisioningState), to_string(sku.name), to_string(tags.\"azd-env-name\"), to_string(location), to_string(properties.targetProvisioningState)])")"; then
    IFS='|' read -r live_state live_sku live_owner live_location live_target_state <<< "$record"
    live_state="${live_state#\"}"; live_state="${live_state%\"}"
    live_sku="${live_sku#\"}"; live_sku="${live_sku%\"}"
    live_owner="${live_owner#\"}"; live_owner="${live_owner%\"}"
    live_location="${live_location#\"}"; live_location="${live_location%\"}"
    live_target_state="${live_target_state#\"}"; live_target_state="${live_target_state%\"}"
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 4 ]; then
    return 4
  fi
  fail "could not read the expected AI Gateway ${resource_group}/${gateway_name}."
}

live_is_deleting() {
  [ "$live_state" = "Deleting" ] || [ "$live_target_state" = "Deleting" ]
}

validate_live_ownership() {
  [ "$live_sku" = "Premium" ] ||
    fail "refusing ${resource_group}/${gateway_name}; expected SKU Premium but found ${live_sku:-unknown}."
  [ "$live_owner" = "$environment_name" ] ||
    fail "refusing ${resource_group}/${gateway_name}; expected azd-env-name=${environment_name} but found ${live_owner:-missing}."
  if [ -n "$live_location" ] && [ "$live_location" != "null" ]; then
    gateway_location="$(normalize_location "$live_location")"
  fi
}

delete_live_gateway() {
  local action="$1"
  echo "${action} environment-owned AI Gateway ${resource_group}/${gateway_name}."
  rest_delete "$service_uri" true ||
    fail "Azure rejected deletion of ${resource_group}/${gateway_name}."
}

settle_gateway() {
  local quiet_start="$1"
  local failure_id="$2"
  local started_at
  local current
  local delay="$poll_initial_seconds"
  local elapsed
  local status
  local surfaces_clear
  started_at="$(now_epoch)"
  while true; do
    surfaces_clear=true
    if load_live_record; then
      validate_live_ownership
      surfaces_clear=false
      quiet_start="$(now_epoch)"
      if live_is_deleting; then
        echo "Waiting for AI Gateway ${gateway_name} to finish deleting."
      elif [ "$mode" = "prepare" ] && [ "$live_state" != "Failed" ]; then
        fail "the expected AI Gateway reappeared in nonterminal state ${live_state:-unknown}; wait for Azure to finish or run an explicit azd down before retrying."
      else
        delete_live_gateway "Deleting"
      fi
    else
      status=$?
      [ "$status" -eq 4 ] || exit "$status"
    fi

    current="$(now_epoch)"
    elapsed=$((current - quiet_start))
    if [ "$surfaces_clear" = true ] && [ "$elapsed" -ge "$identity_settle_seconds" ]; then
      write_marker "settled" "$current" "$failure_id"
      echo "AI Gateway deletion and ${identity_settle_seconds}s identity settle window completed."
      return 0
    fi
    if [ $((current - started_at)) -ge "$operation_timeout_seconds" ]; then
      write_marker "pending" "$quiet_start" "$failure_id"
      fail "cleanup did not remain quiet for ${identity_settle_seconds}s within the ${operation_timeout_seconds}s bound. Wait, then rerun 'azd provision'. If FailedIdentityOperation persists, run 'azd down' and retry 'azd up'."
    fi
    echo "Waiting for AI Gateway deletion and managed-identity cleanup (${elapsed}/${identity_settle_seconds}s quiet)."
    sleep_for "$delay"
    delay="$(next_delay "$delay")"
  done
}

environment_name="$(first_value "${AZURE_ENV_NAME:-}" "$(azd_value AZURE_ENV_NAME)")"
[ -n "$environment_name" ] || fail "AZURE_ENV_NAME is required."

if [ -n "${APIM_LIFECYCLE_STATE_FILE:-}" ]; then
  state_file="$APIM_LIFECYCLE_STATE_FILE"
elif [ -n "${AZD_ENV_FILE:-}" ]; then
  state_file="$(dirname "$AZD_ENV_FILE")/apim-lifecycle.state"
else
  state_file="${REPO_ROOT}/.azure/${environment_name}/apim-lifecycle.state"
fi

marker_environment_name="$(marker_value environment_name)"
if [ -n "$marker_environment_name" ] && [ "$marker_environment_name" != "$environment_name" ]; then
  fail "the lifecycle marker belongs to azd environment ${marker_environment_name}, not ${environment_name}."
fi

subscription_id="$(first_value \
  "${AZURE_SUBSCRIPTION_ID:-}" \
  "$(azd_value AZURE_SUBSCRIPTION_ID)" \
  "$(marker_value subscription_id)" \
  "$(az account show --query id -o tsv 2>/dev/null || true)")"
[ -n "$subscription_id" ] || fail "AZURE_SUBSCRIPTION_ID is required."

resource_group="$(first_value \
  "${AI_GATEWAY_RESOURCE_GROUP:-}" \
  "$(azd_value AI_GATEWAY_RESOURCE_GROUP)" \
  "$(marker_value resource_group)")"
gateway_name="$(first_value \
  "${AI_GATEWAY_NAME:-}" \
  "$(azd_value AI_GATEWAY_NAME)" \
  "$(marker_value gateway_name)")"
gateway_location="$(first_value \
  "${AI_GATEWAY_LOCATION:-}" \
  "$(azd_value AI_GATEWAY_LOCATION)" \
  "$(marker_value location)" \
  "$DEFAULT_AI_GATEWAY_LOCATION")"
gateway_location="$(normalize_location "$gateway_location")"
marker_state="$(marker_value state)"
marker_action_epoch="$(marker_value action_epoch)"
marker_failure_id="$(marker_value failure_id)"
recent_failure_id=""

if [ -z "$resource_group" ] || [ -z "$gateway_name" ]; then
  if ! discover_live_gateway; then
    if ! find_recent_identity_failure; then
      echo "No existing or recently failed AI Gateway belongs to azd environment ${environment_name}; no lifecycle cleanup is needed."
      exit 0
    fi
  fi
fi

[ -n "$resource_group" ] && [ -n "$gateway_name" ] ||
  fail "both AI_GATEWAY_RESOURCE_GROUP and AI_GATEWAY_NAME are required once a lifecycle candidate is found."

gateway_location="$(normalize_location "$gateway_location")"
service_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/aigateways/${gateway_name}"
service_uri="https://management.azure.com${service_resource_id}?api-version=${AI_GATEWAY_API_VERSION}"

live_exists=false
if load_live_record; then
  live_exists=true
  validate_live_ownership
else
  status=$?
  [ "$status" -eq 4 ] || exit "$status"
fi

if [ "$live_exists" = true ]; then
  if [ "$mode" = "prepare" ]; then
    case "$live_state" in
      Succeeded)
        if live_is_deleting; then
          quiet_start="$(now_epoch)"
          write_marker "pending" "$quiet_start" "$marker_failure_id"
          echo "Waiting for environment-owned AI Gateway ${resource_group}/${gateway_name} to finish deleting."
        else
          write_marker "ready" "$(now_epoch)" "$marker_failure_id"
          echo "Preserving healthy environment-owned AI Gateway ${resource_group}/${gateway_name}."
          exit 0
        fi
        ;;
      Failed)
        quiet_start="$(now_epoch)"
        write_marker "pending" "$quiet_start" "$marker_failure_id"
        delete_live_gateway "Recovering terminal-Failed"
        ;;
      *)
        fail "the environment-owned AI Gateway is in nonterminal state ${live_state:-unknown}; it will not be deleted automatically. Wait for Azure to finish or run an explicit azd down."
        ;;
    esac
  else
    quiet_start="$(now_epoch)"
    write_marker "pending" "$quiet_start" "$marker_failure_id"
    if live_is_deleting; then
      echo "Waiting for environment-owned AI Gateway ${resource_group}/${gateway_name} to finish deleting."
    else
      delete_live_gateway "Deleting"
    fi
  fi
else
  if [ "$mode" = "cleanup" ]; then
    quiet_start="$(now_epoch)"
  elif [ "$marker_state" = "pending" ] && [ -n "$marker_action_epoch" ]; then
    quiet_start="$marker_action_epoch"
  elif [ "$marker_state" = "settled" ]; then
    if find_recent_identity_failure && [ "$recent_failure_id" != "$marker_failure_id" ]; then
      service_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/aigateways/${gateway_name}"
      service_uri="https://management.azure.com${service_resource_id}?api-version=${AI_GATEWAY_API_VERSION}"
      quiet_start="$(now_epoch)"
    else
      echo "Previous AI Gateway cleanup is already settled; no lifecycle wait is needed."
      exit 0
    fi
  else
    quiet_start="$(now_epoch)"
  fi
  write_marker "pending" "$quiet_start" "$(first_value "$recent_failure_id" "$marker_failure_id")"
fi

settle_gateway "$quiet_start" "$(first_value "$recent_failure_id" "$marker_failure_id")"
