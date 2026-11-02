#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiled_template="$(mktemp)"
compiled_root_template="$(mktemp)"
trap 'rm -f "$compiled_template" "$compiled_root_template"' EXIT

az bicep build \
  --file "$repo_root/infra/ai-gateway/main.bicep" \
  --outfile "$compiled_template" \
  >/dev/null

actual="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models")
  | .properties.deployment.modelName
' "$compiled_template")"
expected="[last(split(parameters('foundryModels')[copyIndex()].resourceId, '/'))]"

if [ "$actual" != "$expected" ]; then
  echo "Gateway deployment.modelName must come from the Foundry deployment resource ID." >&2
  echo "Expected: $expected" >&2
  echo "Actual:   $actual" >&2
  exit 1
fi

actual_model_policies="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models")
  | .properties.policies
' "$compiled_template")"
for policy_token in \
  "tokenLimit" \
  "period', 'minute" \
  "count', coalesce(tryGet(parameters('foundryModels')[copyIndex()], 'tokenLimit'), 10000)" \
  "counterKey', createArray('identity')" \
  "monthly-caller-budget" \
  "costLimit" \
  "period', 'month" \
  "amount', coalesce(tryGet(parameters('foundryModels')[copyIndex()], 'costLimit'), 10)" \
  "createObject('id', 'monthly-caller-budget', 'type', 'costLimit', 'period', 'month', 'amount', coalesce(tryGet(parameters('foundryModels')[copyIndex()], 'costLimit'), 10), 'counterKey', createArray('identity'))" \
  "contentSafety" \
  "hateSeverity', coalesce(tryGet(parameters('foundryModels')[copyIndex()], 'contentSafetySeverity'), 'Medium')" \
  "selfHarmSeverity', coalesce(tryGet(parameters('foundryModels')[copyIndex()], 'contentSafetySeverity'), 'Medium')" \
  "sexualSeverity', coalesce(tryGet(parameters('foundryModels')[copyIndex()], 'contentSafetySeverity'), 'Medium')" \
  "violenceSeverity', coalesce(tryGet(parameters('foundryModels')[copyIndex()], 'contentSafetySeverity'), 'Medium')"; do
  if ! grep -Fq "$policy_token" <<< "$actual_model_policies"; then
    echo "Gateway model PUTs must include identity-keyed token limits and Medium content safety." >&2
    echo "Missing: $policy_token" >&2
    echo "Actual: $actual_model_policies" >&2
    exit 1
  fi
done

gateway_sku="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways")
  | .sku.name
' "$compiled_template")"
if [ "$gateway_sku" != "Premium" ]; then
  echo "AI Gateway must use the live RP Premium SKU." >&2
  echo "Actual: $gateway_sku" >&2
  exit 1
fi

monitoring_ingestion_mode="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.Insights/components")
  | .properties.AzureMonitorWorkspaceIngestionMode
' "$compiled_template")"
if [ "$monitoring_ingestion_mode" != "Enabled" ]; then
  echo "Gateway Application Insights must enable Azure Monitor workspace ingestion mode." >&2
  echo "Actual: $monitoring_ingestion_mode" >&2
  exit 1
fi

if jq -e '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways/workspaces/telemetryExporters")
' "$compiled_template" >/dev/null; then
  echo "The legacy Bicep telemetry exporter must be configured by the postprovision hook." >&2
  exit 1
fi

actual_aliases="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways/workspaces/aliases")
  | .properties.copy[]
  | select(.name == "backendModels")
  | .input
' "$compiled_template")"
for token in \
  "parameters('modelAliasesConfig')" \
  "Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models" \
  "priority" \
  "weight"; do
  if ! grep -Fq "$token" <<< "$actual_aliases"; then
    echo "Gateway aliases must reference gateway child models and preserve explicit priority and weight routing." >&2
    echo "Missing: $token" >&2
    echo "Actual: $actual_aliases" >&2
    exit 1
  fi
done

alias_has_selection_order="$(jq -r '
  .resources[]
  | select(.type == "Microsoft.ApiManagement/aigateways/workspaces/aliases")
  | .properties | has("selectionOrder")
' "$compiled_template")"
if [ "$alias_has_selection_order" != "false" ]; then
  echo "Live alias PUTs must omit selectionOrder." >&2
  exit 1
fi

az bicep build \
  --file "$repo_root/infra/main.bicep" \
  --outfile "$compiled_root_template" \
  >/dev/null

for output_name in \
  AI_GATEWAY_APP_INSIGHTS_ID \
  AI_GATEWAY_LOG_ANALYTICS_WORKSPACE_ID \
  AI_GATEWAY_PRINCIPAL_ID; do
  if [ "$(jq -r --arg name "$output_name" '.outputs | has($name)' "$compiled_root_template")" != "true" ]; then
    echo "Root Bicep must output $output_name for native OpenTelemetry postprovision." >&2
    exit 1
  fi
done

root_alias_input="$(jq -r '
  .. | objects
  | select(has("modelAliasesConfig"))
  | .modelAliasesConfig.value
  | select(. != null)
' "$compiled_root_template")"

if [[ "$root_alias_input" != *"modelArmName"* ||
  "$root_alias_input" != *"priority"* ||
  "$root_alias_input" != *"weight"* ||
  "$root_alias_input" != *"primary-router"* ]]; then
  echo "Root deployment must create a multi-model alias with explicit priority and weight routes." >&2
  echo "Actual: $root_alias_input" >&2
  exit 1
fi

default_alias_routes="$(jq -r '.variables.effectiveModelAliasBackends' "$compiled_root_template")"
for route in \
  "createObject('modelArmName', parameters('modelDeploymentName'), 'priority', 0, 'weight', 100)" \
  "createObject('modelArmName', parameters('secondaryModelDeploymentName'), 'priority', 1, 'weight', 100)" \
  "createObject('modelArmName', parameters('miniModelDeploymentName'), 'priority', 2, 'weight', 100)"; do
  if ! grep -Fq "$route" <<< "$default_alias_routes"; then
    echo "Default alias routes must configure all three backends with explicit priority and weight." >&2
    echo "Missing: $route" >&2
    echo "Actual: $default_alias_routes" >&2
    exit 1
  fi
done

for setting in \
  "modelName gpt-6.1-sol" \
  "modelVersion 2026-09-29" \
  "secondaryModelName gpt-6-sol" \
  "secondaryModelVersion 2026-09-22" \
  "miniModelName gpt-5.4-mini" \
  "miniModelVersion 2026-03-17"; do
  read -r parameter expected <<< "$setting"
  actual="$(jq -r --arg parameter "$parameter" '.parameters[$parameter].defaultValue' "$compiled_root_template")"
  if [ "$actual" != "$expected" ]; then
    echo "Unexpected default for $parameter." >&2
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    exit 1
  fi
done

root_model_input="$(jq -r '
  .. | objects
  | select(has("foundryModels"))
  | .foundryModels.copy[0].input
  | select(. != null)
' "$compiled_root_template")"
for token in \
  "OpenAIChatCompletions" \
  "/openai/v1/chat/completions" \
  "/openai/v1/responses" \
  "mul(variables('gatewayModelDeployments')[copyIndex('value')].capacity, 1000)" \
  "'costLimit', 10" \
  "'contentSafetySeverity', 'Medium'"; do
  if ! grep -Fq "$token" <<< "$root_model_input"; then
    echo "Root model registrations must use the live RP API, capacity-scaled token limits, and Medium content safety." >&2
    echo "Missing: $token" >&2
    echo "Actual: $root_model_input" >&2
    exit 1
  fi
done

mini_capacity="$(jq -r '.parameters.miniModelCapacity.defaultValue' "$compiled_root_template")"
if [ "$mini_capacity" != "200" ]; then
  echo "Mini deployment capacity must fit ghapp requests with built-in tool definitions." >&2
  echo "Expected: 200" >&2
  echo "Actual:   $mini_capacity" >&2
  exit 1
fi

if ! jq -e '
  .resources[]
  | select(.type == "Microsoft.Resources/deployments" and .properties.parameters.gatewayApiKey != null)
  | . as $module
  | .properties.template as $template
  | (.properties.parameters.gatewayApiKey | tostring) as $key
  | ($module.resourceGroup == "[parameters('\''foundryAgentsResourceGroupName'\'')]")
    and ($module.properties.mode == "Incremental")
    and ($module.condition | contains("deployApimGatewayViaBicep") and contains("foundryAgentsProjectName"))
    and ($template.parameters.gatewayApiKey.type == "securestring")
    and ($key | contains("listSecrets(resourceId('\''Microsoft.ApiManagement/aigateways/apiKeys'\'', parameters('\''gatewayName'\''), '\''default'\''), '\''2025-09-01-preview'\'')") and contains("primaryKey"))
    and ($module.dependsOn | any(contains("Microsoft.ApiManagement/aigateways/apiKeys")))
    and ($module.dependsOn | any(contains("aiGatewayUserRoleDefinitionId")))
    and ($template.resources | length == 1)
    and ($template.parameters.gatewayAudience.defaultValue == "https://azure-api.net/aigateway")
    and ($template.resources[0] |
      .type == "Microsoft.CognitiveServices/accounts/projects/connections"
      and .apiVersion == "2025-06-01"
      and (.name | contains("aigw-github"))
      and (.properties | tostring | (contains("ProjectManagedIdentity") and contains("{0}/default/toolservers/github/mcp") and contains("custom_MCP"))))
' "$compiled_template" >/dev/null; then
  echo "GitHub connection must default to ProjectManagedIdentity on /default/toolservers/github/mcp with AI Gateway User RBAC and primaryKey fallback." >&2
  exit 1
fi

if ! jq -e '
  .resources[]
  | select(.properties.parameters.foundryAgentsProjectName != null)
  | (.properties.parameters.foundryAgentsResourceGroupName.value == "[variables('\''effectiveFoundryAgentsResourceGroupName'\'')]")
    and (.properties.parameters.foundryAgentsAccountName.value | contains("outputs.aiServicesName.value"))
    and (.properties.parameters.foundryAgentsProjectName.value | contains("outputs.aiProjectName.value"))
    and (.properties.parameters.foundryAgentsAccountPrincipalId.value | contains("outputs.aiServicesPrincipalId.value"))
    and (.properties.parameters.foundryAgentsProjectPrincipalId.value | contains("outputs.aiProjectPrincipalId.value"))
    and (.dependsOn | any(contains("foundry-agents-")))
' "$compiled_root_template" >/dev/null; then
  echo "Gateway connection provisioning must wait for the Foundry agents project and pass its managed identity principal IDs." >&2
  exit 1
fi

if ! jq -e '
  [.. | objects | select(.type? == "Microsoft.CognitiveServices/accounts/connections" and .properties.category? == "AppInsights")
   | select(.properties.authType == "ProjectManagedIdentity" and (.properties.metadata.ApplicationInsightsConnectionString != null))]
  | length == 1
' "$compiled_root_template" >/dev/null; then
  echo "Foundry AppInsights connection must use ProjectManagedIdentity with ApplicationInsightsConnectionString metadata." >&2
  exit 1
fi

if ! jq -e '
  [.. | objects | .outputs? // {} | to_entries[]
   | select((.value.value | tostring | test("listSecrets|listValues|parameters\\('\''gatewayApiKey'\''\\)"))
            or (.key | test("(?i)^(gatewayApiKey|AI_GATEWAY_API_KEY|AZURE_AI_GATEWAY_API_KEY)$")))]
  | length == 0
' "$compiled_root_template" >/dev/null; then
  echo "Gateway API key values must never be emitted in deployment outputs." >&2
  exit 1
fi

for hook in "$repo_root/infra/scripts/configure-ai-gateway.sh" "$repo_root/infra/scripts/configure-ai-gateway.ps1"; do
  if grep -Eq 'azd[[:space:]]+ai[[:space:]]+connection[[:space:]]+create|--custom-key' "$hook"; then
    echo "Postprovision must not create the Bicep-owned connection or pass its key to a connection command." >&2
    exit 1
  fi
  for token in \
    '/apiKeys/default/listSecrets?' \
    '--query "key || primaryKey' \
    'azd env set AZURE_AI_GATEWAY_API_KEY' \
    'toolServers/github' \
    'GH_TOKEN' \
    'azd ai toolbox show' \
    'azd ai toolbox create' \
    'Microsoft.Monitor' \
    'DefaultDataCollectionRuleResourceId' \
    'MetricsIngestionEndpoint' \
    'LogsIngestionEndpoint' \
    'TracesIngestionEndpoint' \
    '3913510d-42f4-4e42-8a64-420c390055eb' \
    'OpenTelemetry' \
    'credentials' \
    'managedIdentity' \
    'https://monitor.azure.com' \
    'workspaces/default/telemetryExporters/applicationInsights'; do
    if ! grep -Fq -- "$token" "$hook"; then
      echo "Postprovision must preserve local key retrieval, GitHub registration, Toolbox setup, and OpenTelemetry monitoring: $token" >&2
      echo "Hook: $hook" >&2
      exit 1
    fi
  done
done

if ! grep -Fq 'project_connection_id: aigw-github' "$repo_root/toolbox.yaml"; then
  echo "Toolbox must attach the Bicep-provisioned aigw-github connection." >&2
  exit 1
fi

echo "AI Gateway model registration test passed."
