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

jq -e '
  [.resources[] | select(.type | startswith("Microsoft.ApiManagement/"))] as $resources
  | ($resources | length == 7)
    and all($resources[]; .apiVersion == "2025-09-01-preview")
    and all($resources[]; .type | startswith("Microsoft.ApiManagement/aigateways"))
    and (.variables.telemetryWorkspaceName == "default")
    and ([$resources[] | select(.type == "Microsoft.ApiManagement/aigateways")
      | .sku == {"name": "Consumption"} and .properties == {}
        and .identity.type == "SystemAssigned"] == [true])
    and all($resources[] | select(.type | contains("/workspaces/"));
      .name | contains("variables('\''telemetryWorkspaceName'\'')"))
    and ([$resources[] | select(.type == "Microsoft.ApiManagement/aigateways/apiKeys")
      | .name | contains("telemetryWorkspaceName") | not] == [true])
    and ([$resources[] | select(.type | endswith("/modelProviders"))
      | .properties.displayName != null
        and .properties.foundry.authentication.kind == "ManagedIdentity"] == [true])
    and ([$resources[] | select(.type | endswith("/modelProviders/models"))
      | (.properties | has("policies") | not)
        and .properties.displayName != null
        and (.properties.deployment.modelName
          | contains("last(split(parameters('\''foundryModels'\'')[copyIndex()].resourceId, '\''/'\''))"))] == [true])
    and ([$resources[] | select(.type | endswith("/aliases"))
      | .copy.name == "modelAliases"
        and (.dependsOn | index("foundryCatalogModels") != null)
        and (.properties.aliasName | contains("aliasName"))
        and (.properties.copy[0].input.resourceId
          | contains("resourceId('\''Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models'\''")
            and contains("parameters('\''gatewayName'\'')")
            and contains("variables('\''telemetryWorkspaceName'\'')")
            and contains("parameters('\''foundryProviderName'\'')")
            and contains(".modelArmName")
            and (contains("Microsoft.CognitiveServices") | not))
        and (.properties.copy[0].input.priority | endswith(".priority]"))
        and (.properties.copy[0].input.weight | endswith(".weight]"))] == [true])
    and (.outputs.runtimeHostname.value | contains("frontend") and contains("defaultHostname") and contains("gatewayUrl"))
    and (.outputs.apimGatewayId.value | contains("Microsoft.ApiManagement/aigateways"))
    and (.outputs.modelAliasIds.copy.input | contains("/workspaces/aliases"))
    and (.outputs.defaultModelAliasName.value | contains("aliasName"))
' "$compiled_template" >/dev/null || {
  echo "Standalone AI Gateway resource, workspace, model, or alias contract is incorrect." >&2
  exit 1
}

az bicep build \
  --file "$repo_root/infra/main.bicep" \
  --outfile "$compiled_root_template" \
  >/dev/null

jq -e '
  .parameters as $p
  | (.resources[] | select(.properties.parameters.modelAliasesConfig) | .properties.parameters) as $gateway
  | ($p.modelName.defaultValue == "gpt-6.1-sol")
    and ($p.modelVersion.defaultValue == "2026-09-29")
    and ($p.modelDeploymentName.defaultValue == "gpt-6-1-sol")
    and ($p.modelCapacity.defaultValue == 20)
    and ($p.secondaryModelName.defaultValue == "gpt-6-sol")
    and ($p.secondaryModelVersion.defaultValue == "2026-09-22")
    and ($p.secondaryModelDeploymentName.defaultValue == "gpt-6-sol")
    and ($p.secondaryModelCapacity.defaultValue == 20)
    and ($p.miniModelName.defaultValue == "gpt-5.4-mini")
    and ($p.miniModelVersion.defaultValue == "2026-03-17")
    and ($p.miniModelDeploymentName.defaultValue == "gpt-5-4-mini")
    and ($p.miniModelCapacity.defaultValue == 200)
    and ($p.modelAliasName.defaultValue == "gpt-latest")
    and ($p.miniModelAliasName.defaultValue == "gpt-mini-latest")
    and ($p.modelAliasBackends.defaultValue == [])
    and (.variables.gatewayModelDeployments | length == 3)
    and ([.variables.gatewayModelDeployments[].deploymentName] | sort == [
      "[parameters('\''miniModelDeploymentName'\'')]",
      "[parameters('\''modelDeploymentName'\'')]",
      "[parameters('\''secondaryModelDeploymentName'\'')]"
    ])
    and (.variables.effectiveModelAliasBackends
      | startswith("[if(empty(parameters('\''modelAliasBackends'\''))")
        and contains("parameters('\''modelDeploymentName'\''), '\''priority'\'', 0, '\''weight'\'', 100")
        and contains("parameters('\''secondaryModelDeploymentName'\''), '\''priority'\'', 1, '\''weight'\'', 100")
        and contains("parameters('\''miniModelDeploymentName'\''), '\''priority'\'', 2, '\''weight'\'', 100")
        and endswith("parameters('\''modelAliasBackends'\''))]"))
    and ($gateway.foundryModels.copy[0].input
      | contains("'\''apiFormat'\'', '\''OpenAIChatCompletions'\''")
        and contains("/openai/v1/chat/completions")
        and contains("/openai/v1/responses"))
    and ($gateway.modelAliasesConfig.value | length == 2)
    and ($gateway.modelAliasesConfig.value[0]
      | .armName == "primary-router"
        and .aliasName == "[parameters('\''modelAliasName'\'')]"
        and .backendModels == "[variables('\''effectiveModelAliasBackends'\'')]")
    and ($gateway.modelAliasesConfig.value[1]
      | .armName == "mini-router"
        and .aliasName == "[parameters('\''miniModelAliasName'\'')]"
        and .backendModels == [{
          "modelArmName": "[parameters('\''miniModelDeploymentName'\'')]",
          "priority": 0,
          "weight": 100
        }])
    and (.outputs.AZURE_AI_GATEWAY_MODEL.value == "[parameters('\''modelAliasName'\'')]")
    and (.outputs.AZURE_AI_GATEWAY_MINI_MODEL.value == "[parameters('\''miniModelAliasName'\'')]")
    and (.outputs.AZURE_AI_GATEWAY_MODEL_ALIAS_IDS.value | contains("outputs.modelAliasIds.value"))
    and (.outputs.AI_GATEWAY_INTERNAL_SECONDARY_MODEL_DEPLOYMENT.value == "[parameters('\''secondaryModelDeploymentName'\'')]")
    and (.outputs.AI_GATEWAY_INTERNAL_SECONDARY_MODEL_NAME.value == "[parameters('\''secondaryModelName'\'')]")
    and (.outputs.AI_GATEWAY_INTERNAL_SECONDARY_MODEL_VERSION.value == "[parameters('\''secondaryModelVersion'\'')]")
' "$compiled_root_template" >/dev/null || {
  echo "Three-tier model deployments, alias routing, or public outputs are incorrect." >&2
  exit 1
}

echo "AI Gateway model registration test passed."
