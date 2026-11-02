#!/usr/bin/env bash
set -euo pipefail
umask 077

AI_GATEWAY_API_VERSION="2025-09-01-preview"
LEGACY_AI_GATEWAY_API_VERSION="2025-09-01-preview"
FOUNDRY_USER_ROLE_ID="53ca6127-db72-4b80-b1b0-d745d6d5456d"
MONITORING_METRICS_PUBLISHER_ROLE_ID="3913510d-42f4-4e42-8a64-420c390055eb"
APP_INSIGHTS_API_VERSION="2020-02-02"
ROLE_ASSIGNMENTS_API_VERSION="2022-04-01"
DEFAULT_REPOSITORY="microsoft/agent-framework"
GITHUB_MCP_SERVER="https://api.githubcopilot.com/mcp/"
GITHUB_MCP_TOOLS="list_pull_requests,list_issues,actions_list"
TOOLBOX_NAME="repo-digest-tools"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

azd_value() {
  local value
  if value="$(azd env get-value "$1" 2>/dev/null)"; then
    printf '%s' "$value"
  fi
}

first_value() {
  for value in "$@"; do
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
}

require_value() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "$name is required after azd provision." >&2
    exit 1
  fi
  printf '%s' "$value"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sha256_uuid() {
  local input="$1"
  local hex
  if command -v shasum >/dev/null 2>&1; then
    hex="$(printf '%s' "$input" | shasum -a 256 | awk '{print substr($1,1,32)}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    hex="$(printf '%s' "$input" | sha256sum | awk '{print substr($1,1,32)}')"
  else
    hex="$(printf '%s' "$input" | openssl dgst -sha256 | awk '{print substr($NF,1,32)}')"
  fi
  local b6=$(( (0x${hex:12:2} & 0x0f) | 0x50 ))
  local b8=$(( (0x${hex:16:2} & 0x3f) | 0x80 ))
  printf '%s-%s-%02x%s-%02x%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "$b6" "${hex:14:2}" "$b8" "${hex:18:2}" "${hex:20:12}"
}

validate_github_mcp_credential() {
  local repository="$1"
  local token="$2"
  local least_privilege_doc="IMPLEMENTATION_NOTES.md#tighten-the-github-credential-to-least-privilege"
  local had_warning=false

  if ! [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "GITHUB_REPOSITORY must use the owner/repository format." >&2
    return 1
  fi
  if [ -z "$token" ]; then
    echo "GITHUB_MCP_TOKEN_TO_VALIDATE is required." >&2
    return 1
  fi

  case "$token" in
    github_pat_*|ghs_*)
      local repo_json=""
      if repo_json="$(curl -fsSL --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${token}" \
        -H "User-Agent: foundry-ai-gateway-sample" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${repository}" 2>/dev/null)"; then
        if ! grep -Eq '"pull"[[:space:]]*:[[:space:]]*true' <<< "$repo_json"; then
          echo "Warning: The GitHub credential may not have read access to ${repository}." >&2
          had_warning=true
        fi
        local granted_write=""
        local perm
        for perm in admin maintain push triage; do
          if grep -Eq "\"${perm}\"[[:space:]]*:[[:space:]]*true" <<< "$repo_json"; then
            granted_write="${granted_write:+${granted_write}, }${perm}"
          fi
        done
        if [ -n "$granted_write" ]; then
          echo "Warning: The GitHub credential has write-capable repository permissions (${granted_write}). Prefer a read-only token; see ${least_privilege_doc}" >&2
          had_warning=true
        fi
        local spec description path
        for spec in \
          "repository contents:contents" \
          "repository issues:issues?per_page=1" \
          "repository pull requests:pulls?per_page=1" \
          "repository Actions runs:actions/runs?per_page=1"; do
          description="${spec%%:*}"
          path="${spec#*:}"
          if ! curl -fsSL --max-time 30 \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${token}" \
            -H "User-Agent: foundry-ai-gateway-sample" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/${repository}/${path}" >/dev/null 2>&1; then
            echo "Warning: Could not verify ${description} read access." >&2
            had_warning=true
          fi
        done
      else
        echo "Warning: Could not verify repository read access for ${repository}. Provisioning continues." >&2
        had_warning=true
      fi
      ;;
    *)
      echo "Warning: Using a broad, account-wide GitHub credential (OAuth or classic token). It works, but the postprovision hook stores it in the cloud AI Gateway ToolServer. For the least-privilege fix (GitHub portal and command-line steps), open ${least_privilege_doc}" >&2
      had_warning=true
      ;;
  esac

  if [ "$had_warning" = true ]; then
    echo "Continuing with the selected GitHub credential. See the warnings above to tighten it to least privilege."
  else
    echo "GitHub MCP credential has the required read access and no coarse write role on the target repository."
  fi
}

remove_azd_env_values() {
  local env_file="${AZD_ENV_FILE:-.azure/${environment_name}/.env}"
  [ -f "$env_file" ] || return 0
  local tmp_file
  tmp_file="$(mktemp "${env_file}.tmp.XXXXXX")"
  awk -F= -v keys=" $* " '
    index(keys, " " $1 " ") == 0 { print }
  ' "$env_file" > "$tmp_file"
  mv -f "$tmp_file" "$env_file"
}

get_gateway_api_key_value() {
  local value
  if value="$(az rest \
    --method post \
    --uri "https://management.azure.com${gateway_resource_id}/apiKeys/default/listSecrets?api-version=${AI_GATEWAY_API_VERSION}" \
    --body '{}' \
    --query "key || primaryKey || properties.primaryKey || primaryValue || properties.primaryValue" \
    -o tsv 2>/dev/null)" && [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi

  if value="$(az rest \
    --method post \
    --uri "https://management.azure.com${gateway_resource_id}/apiKeys/default/listValues?api-version=${AI_GATEWAY_API_VERSION}" \
    --body '{}' \
    --query "primaryValue || properties.primaryValue || primaryKey || properties.primaryKey" \
    -o tsv 2>/dev/null)" && [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi

  return 1
}

verify_gateway_model_route() {
  local gateway_url="$1"
  local model="$2"
  local api_key="$3"
  local request_body
  local response_file
  local status=""

  request_body="{\"model\":\"$(json_escape "$model")\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly one word: ok\"}],\"max_completion_tokens\":128}"
  response_file="$(mktemp)"

  for attempt in $(seq 1 15); do
    status="$(curl -sS \
      -o "$response_file" \
      -w '%{http_code}' \
      -X POST \
      "${gateway_url%/}/default/models/openai/v1/chat/completions" \
      -H "Api-Key: ${api_key}" \
      -H "Content-Type: application/json" \
      --data-binary "$request_body" || true)"
    case "$status" in
      2??)
        rm -f "$response_file"
        echo "AI Gateway model route is ready."
        return 0
        ;;
    esac

    if [ "$attempt" -lt 15 ]; then
      echo "Waiting for the AI Gateway model route, attempt=${attempt}, status=${status:-unavailable}"
      sleep 4
    fi
  done

  echo "AI Gateway model route failed with HTTP ${status:-unavailable}. The route requires an explicit Api-Key header." >&2
  if [ -s "$response_file" ]; then
    cat "$response_file" >&2
    echo >&2
  fi
  rm -f "$response_file"
  return 1
}

configure_gateway_monitoring() {
  local monitoring_enabled="$1"
  local gateway_resource_id="$2"
  local subscription_id="$3"
  local gateway_app_insights_id
  local log_analytics_workspace_id
  local gateway_principal_id
  local app_insights_json=""
  local metrics_endpoint=""
  local logs_endpoint=""
  local traces_endpoint=""
  local dcr_scope=""
  local role_assignment_name
  local role_assignment_id
  local role_definition_id
  local role_assignment_body
  local exporter_uri
  local exporter_kind
  local exporter_body
  local provider_state

  case "$monitoring_enabled" in
    true|TRUE|True|1|yes|YES|Yes) ;;
    *)
      echo "AI Gateway monitoring is disabled; skipping OpenTelemetry exporter setup."
      return 0
      ;;
  esac

  gateway_app_insights_id="$(require_value AI_GATEWAY_APP_INSIGHTS_ID "$(first_value "${AI_GATEWAY_APP_INSIGHTS_ID:-}" "$(azd_value AI_GATEWAY_APP_INSIGHTS_ID)")")"
  log_analytics_workspace_id="$(require_value AI_GATEWAY_LOG_ANALYTICS_WORKSPACE_ID "$(first_value "${AI_GATEWAY_LOG_ANALYTICS_WORKSPACE_ID:-}" "$(azd_value AI_GATEWAY_LOG_ANALYTICS_WORKSPACE_ID)")")"
  gateway_principal_id="$(require_value AI_GATEWAY_PRINCIPAL_ID "$(first_value "${AI_GATEWAY_PRINCIPAL_ID:-}" "$(azd_value AI_GATEWAY_PRINCIPAL_ID)")")"

  provider_state="$(az provider show --namespace Microsoft.Monitor --query registrationState -o tsv 2>/dev/null || true)"
  if [ "$provider_state" != "Registered" ]; then
    echo "Registering the Microsoft.Monitor resource provider."
    az provider register --namespace Microsoft.Monitor --wait
  fi

  local ingestion_endpoint=""
  local workspace_resource_id=""
  for attempt in $(seq 1 60); do
    if IFS=$'\t' read -r ingestion_endpoint metrics_endpoint logs_endpoint traces_endpoint dcr_scope workspace_resource_id < <(
      az rest \
        --method get \
        --uri "https://management.azure.com${gateway_app_insights_id}?api-version=${APP_INSIGHTS_API_VERSION}" \
        --query "[properties.IngestionEndpoint || '', properties.MetricsIngestionEndpoint || '', properties.LogsIngestionEndpoint || '', properties.TracesIngestionEndpoint || '', properties.DefaultDataCollectionRuleResourceId || '', properties.WorkspaceResourceId || '']" \
        -o tsv 2>/dev/null | paste -sd $'\t' -
    ) &&
      [ -n "$ingestion_endpoint" ] && [ "$ingestion_endpoint" != "None" ] &&
      [ -n "$metrics_endpoint" ] && [ "$metrics_endpoint" != "None" ] &&
      [ -n "$logs_endpoint" ] && [ "$logs_endpoint" != "None" ] &&
      [ -n "$traces_endpoint" ] && [ "$traces_endpoint" != "None" ] &&
      [ -n "$dcr_scope" ] && [ "$dcr_scope" != "None" ]; then
      break
    fi
    dcr_scope=""
    echo "Waiting for Application Insights managed DCR/DCE and OTLP endpoints, attempt=${attempt}."
    sleep 10
  done
  if [ -z "$dcr_scope" ]; then
    echo "Application Insights did not populate its managed DCR/DCE and OTLP endpoints." >&2
    exit 1
  fi
  if [ "$workspace_resource_id" != "$log_analytics_workspace_id" ]; then
    echo "AI Gateway Application Insights is not connected to the expected Log Analytics workspace." >&2
    exit 1
  fi

  role_assignment_name="$(sha256_uuid "${dcr_scope}|${gateway_principal_id}|${MONITORING_METRICS_PUBLISHER_ROLE_ID}")"
  role_assignment_id="${dcr_scope}/providers/Microsoft.Authorization/roleAssignments/${role_assignment_name}"
  role_definition_id="/subscriptions/${subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${MONITORING_METRICS_PUBLISHER_ROLE_ID}"
  role_assignment_body="{\"properties\":{\"principalId\":\"$(json_escape "$gateway_principal_id")\",\"principalType\":\"ServicePrincipal\",\"roleDefinitionId\":\"$(json_escape "$role_definition_id")\"}}"
  echo "Assigning Monitoring Metrics Publisher at the Application Insights managed DCR scope."
  az rest \
    --method put \
    --uri "https://management.azure.com${role_assignment_id}?api-version=${ROLE_ASSIGNMENTS_API_VERSION}" \
    --body "$role_assignment_body" \
    -o none

  exporter_uri="https://management.azure.com${gateway_resource_id}/workspaces/default/telemetryExporters/applicationInsights?api-version=${AI_GATEWAY_API_VERSION}"
  if exporter_kind="$(az rest --method get --uri "$exporter_uri" --query properties.kind -o tsv 2>/dev/null)" &&
    [ "$exporter_kind" != "OpenTelemetry" ]; then
    echo "Replacing the legacy Application Insights exporter because exporter kind is immutable."
    az rest --method delete --uri "$exporter_uri" -o none
    exporter_deleted=false
    for attempt in $(seq 1 30); do
      if ! az rest --method get --uri "$exporter_uri" -o none 2>/dev/null; then
        exporter_deleted=true
        break
      fi
      echo "Waiting for the legacy telemetry exporter deletion, attempt=${attempt}."
      sleep 2
    done
    if [ "$exporter_deleted" != true ]; then
      echo "The legacy telemetry exporter was not deleted before recreation." >&2
      exit 1
    fi
  fi

  exporter_body="{\"properties\":{\"kind\":\"OpenTelemetry\",\"payloadCapture\":false,\"applicationInsights\":{\"resourceId\":\"$(json_escape "$gateway_app_insights_id")\"},\"openTelemetry\":{\"metricsEndpoint\":\"$(json_escape "$metrics_endpoint")\",\"logsEndpoint\":\"$(json_escape "$logs_endpoint")\",\"tracesEndpoint\":\"$(json_escape "$traces_endpoint")\",\"credentials\":{\"managedIdentity\":{\"resource\":\"https://monitor.azure.com\"}}}}}"
  echo "Configuring the native OpenTelemetry exporter for AI Gateway."
  az rest --method put --uri "$exporter_uri" --body "$exporter_body" -o none
}

prepare_bicep_rbac() {
  local subscription_id
  local resource_group
  local gateway_name
  local gateway_resource_id
  local legacy_gateway_resource_id
  local principal_id
  local account_id
  local expected_assignment_name
  local expected_assignment_principal_id
  local saved_assignment_id
  local assignment_id
  local assignment_name

  subscription_id="$(first_value "${AZURE_SUBSCRIPTION_ID:-}" "$(azd_value AZURE_SUBSCRIPTION_ID)" "$(az account show --query id -o tsv 2>/dev/null || true)")"
  resource_group="$(first_value "${AI_GATEWAY_RESOURCE_GROUP:-}" "$(azd_value AI_GATEWAY_RESOURCE_GROUP)" "${RESOURCE_GROUP:-}" "${AZURE_RESOURCE_GROUP:-}" "$(azd_value RESOURCE_GROUP)" "$(azd_value AZURE_RESOURCE_GROUP)")"
  gateway_name="$(first_value "${AI_GATEWAY_NAME:-}" "$(azd_value AI_GATEWAY_NAME)")"
  if [ -z "$subscription_id" ] || [ -z "$resource_group" ] || [ -z "$gateway_name" ]; then
    return 0
  fi

  gateway_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/aigateways/${gateway_name}"
  legacy_gateway_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${gateway_name}"
  if ! az rest --method get --uri "https://management.azure.com${gateway_resource_id}?api-version=${AI_GATEWAY_API_VERSION}" -o none 2>/dev/null; then
    if az rest --method get --uri "https://management.azure.com${legacy_gateway_resource_id}?api-version=${LEGACY_AI_GATEWAY_API_VERSION}" -o none 2>/dev/null; then
      echo "The environment uses the retired Microsoft.ApiManagement/service AI Gateway resource. Use a fresh azd environment; Bicep will not create a canonical gateway alongside it." >&2
      exit 1
    fi
    return 0
  fi

  principal_id="$(az rest --method get --uri "https://management.azure.com${gateway_resource_id}?api-version=${AI_GATEWAY_API_VERSION}" --query identity.principalId -o tsv)"
  account_id="$(az rest \
    --method get \
    --uri "https://management.azure.com${gateway_resource_id}/workspaces/default/modelProviders/foundry?api-version=${AI_GATEWAY_API_VERSION}" \
    --query 'properties.foundry.resourceIds[0]' \
    -o tsv 2>/dev/null || true)"
  if [ -z "$account_id" ]; then
    account_id="$(azd_value FOUNDRY_MODELS_RESOURCE_ID)"
  fi
  if [ -z "$principal_id" ] || [ -z "$account_id" ]; then
    return 0
  fi

  expected_assignment_name="$(azd_value AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_NAME)"
  expected_assignment_principal_id="$(azd_value AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_PRINCIPAL_ID)"
  if [ -n "$expected_assignment_name" ] && [ "$expected_assignment_principal_id" != "$principal_id" ]; then
    saved_assignment_id="$(az role assignment list \
      --subscription "$subscription_id" \
      --scope "$account_id" \
      --query "[?name=='${expected_assignment_name}'].id | [0]" \
      -o tsv)"
    if [ -n "$saved_assignment_id" ]; then
      echo "Removing the previous Gateway identity's Foundry User assignment."
      az role assignment delete --subscription "$subscription_id" --ids "$saved_assignment_id"
    fi
    expected_assignment_name=""
  fi

  while IFS=$'\t' read -r assignment_id assignment_name; do
    [ -n "$assignment_id" ] || continue
    if [ -n "$expected_assignment_name" ] &&
      [ "$expected_assignment_principal_id" = "$principal_id" ] &&
      [ "$assignment_name" = "$expected_assignment_name" ]; then
      continue
    fi
    echo "Removing the legacy script-owned Foundry User assignment so Bicep can adopt it."
    az role assignment delete --subscription "$subscription_id" --ids "$assignment_id"
  done < <(az role assignment list \
    --subscription "$subscription_id" \
    --assignee-object-id "$principal_id" \
    --scope "$account_id" \
    --role "$FOUNDRY_USER_ROLE_ID" \
    --query '[].[id,name]' \
    -o tsv)
}

if [ "${1:-}" = "--prepare-bicep" ]; then
  bash "$REPO_ROOT/infra/scripts/manage-ai-gateway-lifecycle.sh" prepare
  prepare_bicep_rbac
  exit 0
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--prepare-bicep]" >&2
  exit 2
fi

tool_server_body=""
cleanup() {
  rm -f "$tool_server_body"
}
trap cleanup EXIT

echo "Finishing the Bicep-provisioned AI Gateway with the local GitHub MCP credential."

environment_name="$(require_value AZURE_ENV_NAME "$(first_value "${AZURE_ENV_NAME:-}" "$(azd_value AZURE_ENV_NAME)")")"
subscription_id="$(require_value AZURE_SUBSCRIPTION_ID "$(first_value "${AZURE_SUBSCRIPTION_ID:-}" "$(azd_value AZURE_SUBSCRIPTION_ID)" "$(az account show --query id -o tsv)")")"
resource_group="$(require_value AI_GATEWAY_RESOURCE_GROUP "$(first_value "${AI_GATEWAY_RESOURCE_GROUP:-}" "$(azd_value AI_GATEWAY_RESOURCE_GROUP)" "${RESOURCE_GROUP:-}" "${AZURE_RESOURCE_GROUP:-}" "$(azd_value RESOURCE_GROUP)" "$(azd_value AZURE_RESOURCE_GROUP)")")"
gateway_name="$(require_value AI_GATEWAY_NAME "$(first_value "${AI_GATEWAY_NAME:-}" "$(azd_value AI_GATEWAY_NAME)")")"
gateway_model="$(require_value AZURE_AI_GATEWAY_MODEL "$(first_value "${AZURE_AI_GATEWAY_MODEL:-}" "$(azd_value AZURE_AI_GATEWAY_MODEL)")")"
gateway_mini_model="$(require_value AZURE_AI_GATEWAY_MINI_MODEL "$(first_value "${AZURE_AI_GATEWAY_MINI_MODEL:-}" "$(azd_value AZURE_AI_GATEWAY_MINI_MODEL)")")"
github_repository="$(first_value "${GITHUB_REPOSITORY:-}" "$(azd_value GITHUB_REPOSITORY)" "$DEFAULT_REPOSITORY")"
project_endpoint="$(require_value FOUNDRY_PROJECT_ENDPOINT "$(first_value "${FOUNDRY_PROJECT_ENDPOINT:-}" "$(azd_value FOUNDRY_PROJECT_ENDPOINT)")")"

gateway_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/aigateways/${gateway_name}"
legacy_gateway_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${gateway_name}"
workspace_name="${AI_GATEWAY_WORKSPACE_NAME:-default}"
workspace_resource_id="${gateway_resource_id}/workspaces/${workspace_name}"
gateway_uri="https://management.azure.com${gateway_resource_id}?api-version=${AI_GATEWAY_API_VERSION}"

if ! az rest --method get --uri "$gateway_uri" -o none 2>/dev/null; then
  if az rest --method get --uri "https://management.azure.com${legacy_gateway_resource_id}?api-version=${LEGACY_AI_GATEWAY_API_VERSION}" -o none 2>/dev/null; then
    echo "The environment uses the retired Microsoft.ApiManagement/service AI Gateway resource. Use a fresh azd environment; this hook will not access hidden projected APIM resources." >&2
  else
    echo "Bicep did not create the expected Microsoft.ApiManagement/aigateways resource: ${gateway_name}" >&2
  fi
  exit 1
fi

gateway_state="$(az rest --method get --uri "$gateway_uri" --query properties.provisioningState -o tsv)"
if [ "$gateway_state" != "Succeeded" ]; then
  echo "The Bicep-provisioned AI Gateway is not ready: ${gateway_state:-unknown}" >&2
  exit 1
fi

identity_type="$(az rest --method get --uri "$gateway_uri" --query identity.type -o tsv)"
case "$identity_type" in
  SystemAssigned|"SystemAssigned, UserAssigned") ;;
  *)
    echo "Bicep did not enable the required AI Gateway system-assigned identity." >&2
    exit 1
    ;;
esac

gateway_host="$(require_value AZURE_AI_GATEWAY_ENDPOINT "$(az rest --method get --uri "$gateway_uri" --query 'properties.frontend.defaultHostname || properties.gatewayUrl' -o tsv)")"
case "$gateway_host" in
  https://*) gateway_url="$gateway_host" ;;
  http://*) gateway_url="https://${gateway_host#http://}" ;;
  *) gateway_url="https://${gateway_host}" ;;
esac
case "$gateway_url" in
  */) ;;
  *) gateway_url="${gateway_url}/" ;;
esac

workspace_children_ready=false
for attempt in $(seq 1 30); do
  if az rest --method get --uri "https://management.azure.com${workspace_resource_id}/modelProviders?api-version=${AI_GATEWAY_API_VERSION}" -o none 2>/dev/null; then
    workspace_children_ready=true
    break
  fi
  echo "Waiting for the Bicep-provisioned default workspace, attempt=${attempt}"
  sleep 2
done
if [ "$workspace_children_ready" != true ]; then
  echo "AI Gateway did not expose child APIs for the required ${workspace_name} workspace." >&2
  exit 1
fi

provider_auth="$(az rest \
  --method get \
  --uri "https://management.azure.com${workspace_resource_id}/modelProviders/foundry?api-version=${AI_GATEWAY_API_VERSION}" \
  --query properties.foundry.authentication.kind \
  -o tsv)"
if [ "$provider_auth" != "ManagedIdentity" ]; then
  echo "Bicep did not configure the Foundry provider for managed identity." >&2
  exit 1
fi

monitoring_enabled="$(first_value "${ENABLE_MONITORING:-}" "$(azd_value ENABLE_MONITORING)" "true")"
configure_gateway_monitoring "$monitoring_enabled" "$gateway_resource_id" "$subscription_id"

remove_azd_env_values GITHUB_MCP_TOKEN GITHUB_TOKEN
github_token=""
if command -v gh >/dev/null 2>&1; then
  if [ -n "${GITHUB_MCP_GH_USER:-}" ]; then
    github_token="$(env -u GITHUB_TOKEN gh auth token --hostname github.com --user "$GITHUB_MCP_GH_USER" 2>/dev/null || true)"
  else
    github_token="$(env -u GITHUB_TOKEN gh auth token --hostname github.com 2>/dev/null || true)"
  fi
fi
if [ -z "$github_token" ]; then
  echo "GitHub authentication is required for GitHub MCP. Run 'gh auth login --hostname github.com', or provide GH_TOKEN to GitHub CLI in CI." >&2
  exit 1
fi
validate_github_mcp_credential "$github_repository" "$github_token"
echo "Using the active GitHub CLI login for GitHub MCP."
case "$github_token" in
  Bearer\ *) github_authorization="$github_token" ;;
  *) github_authorization="Bearer $github_token" ;;
esac

tool_server_body="$(mktemp)"
cat > "$tool_server_body" <<EOF
{
  "properties": {
    "displayName": "GitHub repository digest",
    "description": "Read-only GitHub tools for repository digests.",
    "type": "mcp",
    "failureMode": "failClosed",
    "policies": [{
      "type": "contentSafety",
      "hateSeverity": "Medium",
      "selfHarmSeverity": "Medium",
      "sexualSeverity": "Medium",
      "violenceSeverity": "Medium"
    }],
    "endpoints": [{
      "namespace": "github",
      "kind": "mcp",
      "mcp": {
        "url": "$(json_escape "$GITHUB_MCP_SERVER")",
        "transport": "streamableHttp"
      },
      "credentials": {
        "type": "header",
        "headers": {
          "Authorization": ["$(json_escape "$github_authorization")"],
          "X-MCP-Readonly": ["true"],
          "X-MCP-Tools": ["$(json_escape "$GITHUB_MCP_TOOLS")"]
        }
      }
    }]
  }
}
EOF

echo "Injecting the read-only GitHub MCP credential into the Bicep-provisioned ToolServer."
az rest \
  --method put \
  --uri "https://management.azure.com${workspace_resource_id}/toolServers/github?api-version=${AI_GATEWAY_API_VERSION}" \
  --body @"$tool_server_body" \
  -o none
rm -f "$tool_server_body"
tool_server_body=""
unset github_token github_authorization

saved_gateway_api_key="$(first_value "${AZURE_AI_GATEWAY_API_KEY:-}" "$(azd_value AZURE_AI_GATEWAY_API_KEY)")"
if ! gateway_api_key="$(get_gateway_api_key_value)"; then
  gateway_api_key="$saved_gateway_api_key"
fi
gateway_api_key="$(require_value AZURE_AI_GATEWAY_API_KEY "$gateway_api_key")"

verify_gateway_model_route "$gateway_url" "$gateway_model" "$gateway_api_key"

azd env set AZURE_AI_GATEWAY_ENDPOINT "$gateway_url"
azd env set AZURE_AI_GATEWAY_MODEL "$gateway_model"
azd env set AZURE_AI_GATEWAY_MINI_MODEL "$gateway_mini_model"
azd env set GITHUB_REPOSITORY "$github_repository"
azd env set AZURE_AI_GATEWAY_API_KEY "$gateway_api_key" >/dev/null
azd env set TOOLBOX_NAME "$TOOLBOX_NAME"

echo "Connecting Foundry Toolbox using the Bicep-provisioned aigw-github connection."

if ! toolbox_json="$(azd ai toolbox show "$TOOLBOX_NAME" \
  --no-prompt \
  --project-endpoint "$project_endpoint" \
  -o json 2>/dev/null)"; then
  echo "Creating the Foundry Toolbox."
  toolbox_json="$(azd ai toolbox create "$TOOLBOX_NAME" \
    --from-file "$REPO_ROOT/toolbox.yaml" \
    --no-prompt \
    --project-endpoint "$project_endpoint" \
    -o json)"
fi
toolbox_endpoint="$(sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$toolbox_json" | head -n 1)"
toolbox_endpoint="$(require_value TOOLBOX_ENDPOINT "$toolbox_endpoint")"
azd env set TOOLBOX_ENDPOINT "$toolbox_endpoint"
remove_azd_env_values \
  AI_SERVICES_NAME \
  AI_GATEWAY_INTERNAL_MODEL_DEPLOYMENT \
  AI_GATEWAY_INTERNAL_MODEL_NAME \
  AI_GATEWAY_INTERNAL_MODEL_VERSION \
  AI_GATEWAY_INTERNAL_SECONDARY_MODEL_DEPLOYMENT \
  AI_GATEWAY_INTERNAL_SECONDARY_MODEL_NAME \
  AI_GATEWAY_INTERNAL_SECONDARY_MODEL_VERSION \
  AI_GATEWAY_INTERNAL_MINI_MODEL_DEPLOYMENT \
  AI_GATEWAY_INTERNAL_MINI_MODEL_NAME \
  AI_GATEWAY_INTERNAL_MINI_MODEL_VERSION \
  MODEL_DEPLOYMENT_NAME \
  AZURE_AI_MODEL_DEPLOYMENT_NAME \
  MODEL_NAME \
  MODEL_VERSION \
  LATEST_MODEL_DEPLOYMENT_NAME \
  LATEST_MODEL_NAME \
  LATEST_MODEL_VERSION \
  AI_PROJECT_DEPLOYMENTS \
  AZURE_AI_GATEWAY_MODEL_ALIAS \
  AZURE_AI_GATEWAY_MODEL_VERSION \
  AZURE_AI_GATEWAY_BASE_MODEL \
  AZURE_AI_GATEWAY_BASE_MINI_MODEL \
  AZURE_AI_GATEWAY_LATEST_MODEL_ALIAS \
  AZURE_AI_GATEWAY_LATEST_MODEL \
  AZURE_AI_GATEWAY_LATEST_MODEL_VERSION \
  AZURE_AI_GATEWAY_MODEL_ALIASES \
  AZURE_AI_GATEWAY_MODELS \
  GITHUB_MCP_TOKEN \
  GITHUB_TOKEN \
  FOUNDRY_API_KEY

"$REPO_ROOT/scripts/create-dev-env.sh" --force

echo "AI Gateway setup complete. Bicep owns Azure resources; this hook injects the GitHub credential, connects Foundry Toolbox to AI Gateway, and saves the runtime key."
