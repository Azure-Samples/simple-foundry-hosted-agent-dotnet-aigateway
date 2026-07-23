#!/usr/bin/env bash
set -euo pipefail
umask 077

AI_GATEWAY_API_VERSION="2025-09-01-preview"
LEGACY_AI_GATEWAY_API_VERSION="2026-05-01"
FOUNDRY_USER_ROLE_ID="53ca6127-db72-4b80-b1b0-d745d6d5456d"
DEFAULT_REPOSITORY="microsoft/agent-framework"
GITHUB_MCP_SERVER="https://api.githubcopilot.com/mcp/"
GITHUB_MCP_TOOLS="list_pull_requests,list_issues,actions_list"
TOOLBOX_CONNECTION_NAME="aigw-github"
TOOLBOX_NAME="repo-digest-tools"
LEAST_PRIVILEGE_FIX_DOC="docs/implementation-notes.md#tighten-the-github-credential-to-least-privilege"
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

verify_github_access() {
  local repository="$1"
  local token="$2"
  local endpoint

  if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "GITHUB_REPOSITORY must use the owner/repository format." >&2
    exit 1
  fi

  # Advisory only: never block provisioning. Warn when the selected credential is
  # broader than the recommended least-privilege token, so the documented
  # 'gh auth status; azd up' flow keeps working while still nudging operators
  # toward a fine-grained, repository-scoped, read-only token.
  case "$token" in
    github_pat_*|ghs_*) ;;
    *)
      echo "Warning: using a broad, account-wide GitHub credential (OAuth or classic token)." >&2
      echo "It works, but the postprovision hook stores it in the cloud AI Gateway ToolServer." >&2
      echo "For the least-privilege fix, see ${LEAST_PRIVILEGE_FIX_DOC}" >&2
      return 0
      ;;
  esac

  for endpoint in \
    "repos/${repository}" \
    "repos/${repository}/pulls?per_page=1" \
    "repos/${repository}/issues?per_page=1" \
    "repos/${repository}/actions/runs?per_page=1"; do
    if ! GH_TOKEN="$token" gh api "$endpoint" --silent >/dev/null 2>&1; then
      echo "Warning: could not verify read access at ${endpoint%%\?*}. Provisioning continues." >&2
      echo "Prefer a repo-scoped, read-only credential; see ${LEAST_PRIVILEGE_FIX_DOC}" >&2
    fi
  done
}

remove_azd_env_values() {
  local env_file="${AZD_ENV_FILE:-.azure/${environment_name}/.env}"
  [ -f "$env_file" ] || return 0
  python3 - "$env_file" "$@" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
remove = set(sys.argv[2:])
lines = path.read_text().splitlines()
path.write_text("\n".join(line for line in lines if line.split("=", 1)[0] not in remove) + "\n")
PY
}

get_gateway_api_key_value() {
  local value
  if value="$(az rest \
    --method post \
    --uri "https://management.azure.com${gateway_resource_id}/apiKeys/default/listSecrets?api-version=${AI_GATEWAY_API_VERSION}" \
    --body '{}' \
    --query "primaryKey || properties.primaryKey || primaryValue || properties.primaryValue" \
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

  request_body="$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "messages": [{"role": "user", "content": "Reply with exactly one word: ok"}], "max_completion_tokens": 128}))' "$model")"
  response_file="$(mktemp)"

  for attempt in $(seq 1 15); do
    status="$(curl -sS \
      -o "$response_file" \
      -w '%{http_code}' \
      --connect-timeout 10 \
      --max-time 30 \
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

  gateway_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${gateway_name}"
  legacy_gateway_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/aigateways/${gateway_name}"
  if ! az rest --method get --uri "https://management.azure.com${gateway_resource_id}?api-version=${AI_GATEWAY_API_VERSION}" -o none 2>/dev/null; then
    if az rest --method get --uri "https://management.azure.com${legacy_gateway_resource_id}?api-version=${LEGACY_AI_GATEWAY_API_VERSION}" -o none 2>/dev/null; then
      echo "The environment uses the retired Microsoft.ApiManagement/aigateways resource. Use a fresh azd environment; Bicep will not create a canonical service alongside it." >&2
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

gateway_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/service/${gateway_name}"
legacy_gateway_resource_id="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ApiManagement/aigateways/${gateway_name}"
workspace_name="${AI_GATEWAY_WORKSPACE_NAME:-default}"
workspace_resource_id="${gateway_resource_id}/workspaces/${workspace_name}"
gateway_uri="https://management.azure.com${gateway_resource_id}?api-version=${AI_GATEWAY_API_VERSION}"

if ! az rest --method get --uri "$gateway_uri" -o none 2>/dev/null; then
  if az rest --method get --uri "https://management.azure.com${legacy_gateway_resource_id}?api-version=${LEGACY_AI_GATEWAY_API_VERSION}" -o none 2>/dev/null; then
    echo "The environment uses the retired Microsoft.ApiManagement/aigateways resource. Use a fresh azd environment; this hook will not access hidden projected APIM resources." >&2
  else
    echo "Bicep did not create the expected Microsoft.ApiManagement/service AI Gateway: ${gateway_name}" >&2
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

gateway_url="$(require_value AZURE_AI_GATEWAY_ENDPOINT "$(az rest --method get --uri "$gateway_uri" --query properties.gatewayUrl -o tsv)")"
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
verify_github_access "$github_repository" "$github_token"
echo "Using the active GitHub CLI login for GitHub MCP."
case "$github_token" in
  Bearer\ *) github_authorization="$github_token" ;;
  *) github_authorization="Bearer $github_token" ;;
esac

tool_server_body="$(mktemp)"
export GITHUB_MCP_AUTHORIZATION="$github_authorization"
export GITHUB_MCP_SERVER
export GITHUB_MCP_TOOLS
python3 - <<'PY' > "$tool_server_body"
import json
import os

print(json.dumps({
    "properties": {
        "displayName": "GitHub repository digest",
        "description": "Read-only GitHub tools for repository digests.",
        "type": "mcp",
        "failureMode": "failClosed",
        "endpoints": [{
            "namespace": "github",
            "kind": "mcp",
            "mcp": {
                "url": os.environ["GITHUB_MCP_SERVER"],
                "transport": "streamableHttp",
            },
            "credentials": {
                "type": "header",
                "headers": {
                    "Authorization": [os.environ["GITHUB_MCP_AUTHORIZATION"]],
                    "X-MCP-Readonly": ["true"],
                    "X-MCP-Tools": [os.environ["GITHUB_MCP_TOOLS"]],
                },
            },
        }],
    }
}))
PY

echo "Injecting the read-only GitHub MCP credential into the Bicep-provisioned ToolServer."
az rest \
  --method put \
  --uri "https://management.azure.com${workspace_resource_id}/toolServers/github?api-version=${AI_GATEWAY_API_VERSION}" \
  --body @"$tool_server_body" \
  -o none
rm -f "$tool_server_body"
tool_server_body=""
unset github_token github_authorization GITHUB_MCP_AUTHORIZATION

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

echo "Connecting Foundry Toolbox to the AI Gateway GitHub ToolServer."
azd ai connection create "$TOOLBOX_CONNECTION_NAME" \
  --kind remote-tool \
  --target "${gateway_url%/}/default/toolservers/github/mcp" \
  --auth-type custom-keys \
  --custom-key "Api-Key=${gateway_api_key}" \
  --force \
  --no-prompt \
  --project-endpoint "$project_endpoint" \
  -o json >/dev/null

if ! toolbox_json="$(azd ai toolbox show "$TOOLBOX_NAME" \
  --no-prompt \
  --project-endpoint "$project_endpoint" \
  -o json 2>/dev/null)"; then
  echo "Creating the Foundry Toolbox."
  toolbox_json="$(azd ai toolbox create "$TOOLBOX_NAME" \
    --from-file "$REPO_ROOT/infra/toolbox.yaml" \
    --no-prompt \
    --project-endpoint "$project_endpoint" \
    -o json)"
fi
toolbox_endpoint="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["endpoint"])' <<< "$toolbox_json")"
azd env set TOOLBOX_ENDPOINT "$toolbox_endpoint"
remove_azd_env_values \
  AI_SERVICES_NAME \
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

echo "AI Gateway setup complete. Bicep owns Azure resources; this hook injects the GitHub credential, connects Foundry Toolbox to AI Gateway, and saves the runtime key."
