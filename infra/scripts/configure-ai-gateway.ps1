#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [switch]$PrepareBicep
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$aiGatewayApiVersion = "2025-09-01-preview"
$legacyApiVersion = "2026-05-01"
$foundryUserRoleId = "53ca6127-db72-4b80-b1b0-d745d6d5456d"
$defaultRepository = "microsoft/agent-framework"
$githubMcpServer = "https://api.githubcopilot.com/mcp/"
$githubMcpTools = "list_pull_requests,list_issues,actions_list"
$toolboxConnectionName = "aigw-github"
$toolboxName = "repo-digest-tools"
$leastPrivilegeFixDoc = "docs/implementation-notes.md#tighten-the-github-credential-to-least-privilege"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path

function Get-AzdValue([string]$Name) {
    try {
        return ([string](azd env get-value $Name 2>$null)).Trim()
    } catch {
        return ""
    }
}

function Get-FirstValue([string[]]$Values) {
    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    return ""
}

function Test-GatewayModelRoute([string]$GatewayUrl, [string]$Model, [string]$ApiKey) {
    $uri = $GatewayUrl.TrimEnd("/") + "/default/models/openai/v1/chat/completions"
    $headers = @{ "Api-Key" = $ApiKey }
    $body = @{
        model = $Model
        messages = @(
            @{
                role = "user"
                content = "Reply with exactly one word: ok"
            }
        )
        max_completion_tokens = 128
    } | ConvertTo-Json -Depth 5 -Compress
    $lastError = ""

    for ($attempt = 1; $attempt -le 15; $attempt++) {
        try {
            Invoke-RestMethod `
                -Method Post `
                -Uri $uri `
                -Headers $headers `
                -ContentType "application/json" `
                -ConnectionTimeoutSeconds 10 `
                -OperationTimeoutSeconds 30 `
                -Body $body | Out-Null
            Write-Host "AI Gateway model route is ready."
            return
        } catch {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $responseBody = [string]$_.ErrorDetails.Message
            $lastError = "HTTP $statusCode"
            if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                $lastError += ": $responseBody"
            } else {
                $lastError += ": $($_.Exception.Message)"
            }
            if ($attempt -lt 15) {
                Write-Host "Waiting for the AI Gateway model route, attempt=$attempt, status=$statusCode"
                Start-Sleep -Seconds 4
            }
        }
    }

    throw "AI Gateway model route failed. The route requires an explicit Api-Key header. Last response: $lastError"
}

function Require-Value([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required after azd provision."
    }
    return $Value
}

function Assert-GitHubAccess([string]$Repository, [string]$Token) {
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "GITHUB_REPOSITORY must use the owner/repository format."
    }

    # Advisory only: never block provisioning. Warn when the selected credential
    # is broader than the recommended least-privilege token, so the documented
    # 'gh auth status; azd up' flow keeps working while still nudging operators
    # toward a fine-grained, repository-scoped, read-only token.
    if ($Token -notmatch '^(github_pat_|ghs_)') {
        Write-Warning "Using a broad, account-wide GitHub credential (OAuth or classic token). It works, but the postprovision hook stores it in the cloud AI Gateway ToolServer. For the least-privilege fix, see $leastPrivilegeFixDoc"
        return
    }

    $previousToken = $env:GH_TOKEN
    try {
        $env:GH_TOKEN = $Token
        foreach ($endpoint in @(
            "repos/$Repository",
            "repos/$Repository/pulls?per_page=1",
            "repos/$Repository/issues?per_page=1",
            "repos/$Repository/actions/runs?per_page=1"
        )) {
            try {
                gh api $endpoint --silent 2>$null
            } catch {
                Write-Warning "Could not verify read access at $($endpoint.Split('?')[0]). Provisioning continues. Prefer a repo-scoped, read-only credential; see $leastPrivilegeFixDoc"
            }
        }
    } finally {
        $env:GH_TOKEN = $previousToken
    }
}

function Remove-AzdEnvValues([string[]]$Names) {
    $environmentName = Get-FirstValue @($env:AZURE_ENV_NAME, (Get-AzdValue "AZURE_ENV_NAME"))
    $envFile = Get-FirstValue @($env:AZD_ENV_FILE, ".azure/$environmentName/.env")
    if (-not (Test-Path $envFile)) {
        return
    }
    $remove = [Collections.Generic.HashSet[string]]::new(
        $Names,
        [StringComparer]::Ordinal
    )
    $lines = Get-Content $envFile | Where-Object {
        -not $remove.Contains(($_ -split "=", 2)[0])
    }
    [IO.File]::WriteAllLines($envFile, $lines, [Text.UTF8Encoding]::new($false))
}

function Get-OptionalAzRestResource([string]$Uri) {
    $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $outputLines = @(& az rest --method get --uri $Uri -o json 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    }

    $body = ($outputLines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($exitCode -eq 0) {
        return $body | ConvertFrom-Json
    }
    if ($body -match '(?im)(^ERROR:\s*(\((NotFound|ResourceNotFound)\)|(Not Found|NotFound|ResourceNotFound)([\s:({]|$))|"code"\s*:\s*"(NotFound|ResourceNotFound)"|"status(Code)?"\s*:\s*404)') {
        return $null
    }
    throw "Azure REST GET failed for $Uri. $body"
}

function Prepare-BicepRbac {
    $subscriptionId = Get-FirstValue @(
        $env:AZURE_SUBSCRIPTION_ID,
        (Get-AzdValue "AZURE_SUBSCRIPTION_ID"),
        ([string](az account show --query id -o tsv 2>$null)).Trim()
    )
    $resourceGroup = Get-FirstValue @(
        $env:AI_GATEWAY_RESOURCE_GROUP,
        (Get-AzdValue "AI_GATEWAY_RESOURCE_GROUP"),
        $env:RESOURCE_GROUP,
        $env:AZURE_RESOURCE_GROUP,
        (Get-AzdValue "RESOURCE_GROUP"),
        (Get-AzdValue "AZURE_RESOURCE_GROUP")
    )
    $gatewayName = Get-FirstValue @(
        $env:AI_GATEWAY_NAME,
        (Get-AzdValue "AI_GATEWAY_NAME")
    )
    if (
        [string]::IsNullOrWhiteSpace($subscriptionId) -or
        [string]::IsNullOrWhiteSpace($resourceGroup) -or
        [string]::IsNullOrWhiteSpace($gatewayName)
    ) {
        return
    }

    $gatewayResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$gatewayName"
    $legacyResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/aigateways/$gatewayName"
    $gateway = Get-OptionalAzRestResource "https://management.azure.com${gatewayResourceId}?api-version=$aiGatewayApiVersion"
    if ($null -eq $gateway) {
        $legacy = Get-OptionalAzRestResource "https://management.azure.com${legacyResourceId}?api-version=$legacyApiVersion"
        if ($null -ne $legacy) {
            throw "The environment uses the retired Microsoft.ApiManagement/aigateways resource. Use a fresh azd environment; Bicep will not create a canonical service alongside it."
        }
        return
    }

    $principalId = [string]$gateway.identity.principalId
    $provider = Get-OptionalAzRestResource "https://management.azure.com${gatewayResourceId}/workspaces/default/modelProviders/foundry?api-version=$aiGatewayApiVersion"
    $accountId = if ($null -ne $provider) {
        [string]$provider.properties.foundry.resourceIds[0]
    } else {
        ""
    }
    if ([string]::IsNullOrWhiteSpace($accountId)) {
        $accountId = Get-AzdValue "FOUNDRY_MODELS_RESOURCE_ID"
    }
    if (
        [string]::IsNullOrWhiteSpace($principalId) -or
        [string]::IsNullOrWhiteSpace($accountId)
    ) {
        return
    }

    $expectedAssignmentName = Get-AzdValue "AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_NAME"
    $expectedPrincipalId = Get-AzdValue "AI_GATEWAY_FOUNDRY_ROLE_ASSIGNMENT_PRINCIPAL_ID"
    if (
        -not [string]::IsNullOrWhiteSpace($expectedAssignmentName) -and
        $expectedPrincipalId -ne $principalId
    ) {
        $savedAssignmentId = ([string](az role assignment list `
            --subscription $subscriptionId `
            --scope $accountId `
            --query "[?name=='$expectedAssignmentName'].id | [0]" `
            -o tsv)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($savedAssignmentId)) {
            Write-Host "Removing the previous Gateway identity's Foundry User assignment."
            az role assignment delete --subscription $subscriptionId --ids $savedAssignmentId
        }
        $expectedAssignmentName = ""
    }

    $assignments = @(
        az role assignment list `
            --subscription $subscriptionId `
            --assignee-object-id $principalId `
            --scope $accountId `
            --role $foundryUserRoleId `
            --query "[].{id:id,name:name}" `
            -o json | ConvertFrom-Json
    )
    foreach ($assignment in $assignments) {
        if (
            -not [string]::IsNullOrWhiteSpace($expectedAssignmentName) -and
            $expectedPrincipalId -eq $principalId -and
            [string]$assignment.name -eq $expectedAssignmentName
        ) {
            continue
        }
        Write-Host "Removing the legacy script-owned Foundry User assignment so Bicep can adopt it."
        az role assignment delete --subscription $subscriptionId --ids ([string]$assignment.id)
    }
}

if ($PrepareBicep) {
    & (Join-Path $PSScriptRoot "manage-ai-gateway-lifecycle.ps1") prepare
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    Prepare-BicepRbac
    exit 0
}

$environmentName = Require-Value "AZURE_ENV_NAME" (Get-FirstValue @(
    $env:AZURE_ENV_NAME,
    (Get-AzdValue "AZURE_ENV_NAME")
))
$subscriptionId = Require-Value "AZURE_SUBSCRIPTION_ID" (Get-FirstValue @(
    $env:AZURE_SUBSCRIPTION_ID,
    (Get-AzdValue "AZURE_SUBSCRIPTION_ID"),
    ([string](az account show --query id -o tsv)).Trim()
))
$resourceGroup = Require-Value "AI_GATEWAY_RESOURCE_GROUP" (Get-FirstValue @(
    $env:AI_GATEWAY_RESOURCE_GROUP,
    (Get-AzdValue "AI_GATEWAY_RESOURCE_GROUP"),
    $env:RESOURCE_GROUP,
    $env:AZURE_RESOURCE_GROUP,
    (Get-AzdValue "RESOURCE_GROUP"),
    (Get-AzdValue "AZURE_RESOURCE_GROUP")
))
$gatewayName = Require-Value "AI_GATEWAY_NAME" (Get-FirstValue @(
    $env:AI_GATEWAY_NAME,
    (Get-AzdValue "AI_GATEWAY_NAME")
))
$gatewayModel = Require-Value "AZURE_AI_GATEWAY_MODEL" (Get-FirstValue @(
    $env:AZURE_AI_GATEWAY_MODEL,
    (Get-AzdValue "AZURE_AI_GATEWAY_MODEL")
))
$gatewayMiniModel = Require-Value "AZURE_AI_GATEWAY_MINI_MODEL" (Get-FirstValue @(
    $env:AZURE_AI_GATEWAY_MINI_MODEL,
    (Get-AzdValue "AZURE_AI_GATEWAY_MINI_MODEL")
))
$githubRepository = Get-FirstValue @(
    $env:GITHUB_REPOSITORY,
    (Get-AzdValue "GITHUB_REPOSITORY"),
    $defaultRepository
)
$projectEndpoint = Require-Value "FOUNDRY_PROJECT_ENDPOINT" (Get-FirstValue @(
    $env:FOUNDRY_PROJECT_ENDPOINT,
    (Get-AzdValue "FOUNDRY_PROJECT_ENDPOINT")
))

$gatewayResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$gatewayName"
$legacyResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/aigateways/$gatewayName"
$workspaceName = Get-FirstValue @($env:AI_GATEWAY_WORKSPACE_NAME, "default")
$workspaceResourceId = "$gatewayResourceId/workspaces/$workspaceName"
$gatewayUri = "https://management.azure.com${gatewayResourceId}?api-version=$aiGatewayApiVersion"

try {
    $gateway = az rest --method get --uri $gatewayUri -o json | ConvertFrom-Json
} catch {
    $legacyUri = "https://management.azure.com${legacyResourceId}?api-version=$legacyApiVersion"
    try {
        az rest --method get --uri $legacyUri -o none 2>$null
        throw "The environment uses the retired Microsoft.ApiManagement/aigateways resource. Use a fresh azd environment."
    } catch {
        throw "Bicep did not create the expected Microsoft.ApiManagement/service AI Gateway: $gatewayName"
    }
}

if ($gateway.properties.provisioningState -ne "Succeeded") {
    throw "The Bicep-provisioned AI Gateway is not ready: $($gateway.properties.provisioningState)"
}
if ($gateway.identity.type -notin @("SystemAssigned", "SystemAssigned, UserAssigned")) {
    throw "Bicep did not enable the required AI Gateway system-assigned identity."
}

$gatewayUrl = Require-Value "AZURE_AI_GATEWAY_ENDPOINT" ([string]$gateway.properties.gatewayUrl)
if (-not $gatewayUrl.EndsWith("/", [StringComparison]::Ordinal)) {
    $gatewayUrl += "/"
}

$providerUri = "https://management.azure.com${workspaceResourceId}/modelProviders/foundry?api-version=$aiGatewayApiVersion"
$providerAuth = ([string](az rest --method get --uri $providerUri --query properties.foundry.authentication.kind -o tsv)).Trim()
if ($providerAuth -ne "ManagedIdentity") {
    throw "Bicep did not configure the Foundry provider for managed identity."
}

Remove-AzdEnvValues @("GITHUB_MCP_TOKEN", "GITHUB_TOKEN")
$githubToken = ""
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_MCP_GH_USER)) {
    $githubToken = ([string](gh auth token --hostname github.com --user $env:GITHUB_MCP_GH_USER 2>$null)).Trim()
} else {
    $githubToken = ([string](gh auth token --hostname github.com 2>$null)).Trim()
}
if ([string]::IsNullOrWhiteSpace($githubToken)) {
    throw "GitHub authentication is required. Run 'gh auth login --hostname github.com'."
}
Assert-GitHubAccess $githubRepository $githubToken
$githubAuthorization = if ($githubToken.StartsWith("Bearer ", [StringComparison]::OrdinalIgnoreCase)) {
    $githubToken
} else {
    "Bearer $githubToken"
}

$toolServerBody = @{
    properties = @{
        displayName = "GitHub repository digest"
        description = "Read-only GitHub tools for repository digests."
        type = "mcp"
        failureMode = "failClosed"
        endpoints = @(
            @{
                namespace = "github"
                kind = "mcp"
                mcp = @{
                    url = $githubMcpServer
                    transport = "streamableHttp"
                }
                credentials = @{
                    type = "header"
                    headers = @{
                        Authorization = @($githubAuthorization)
                        "X-MCP-Readonly" = @("true")
                        "X-MCP-Tools" = @($githubMcpTools)
                    }
                }
            }
        )
    }
} | ConvertTo-Json -Depth 12 -Compress

$toolServerUri = "https://management.azure.com${workspaceResourceId}/toolServers/github?api-version=$aiGatewayApiVersion"
Write-Host "Injecting the read-only GitHub MCP credential into the Bicep-provisioned ToolServer."
$toolServerBodyPath = Join-Path ([IO.Path]::GetTempPath()) "aigw-toolserver-$([Guid]::NewGuid().ToString('N')).json"
try {
    if ($IsWindows) {
        [IO.File]::WriteAllText($toolServerBodyPath, $toolServerBody, [Text.UTF8Encoding]::new($false))
    } else {
        $options = [IO.FileStreamOptions]::new()
        $options.Mode = [IO.FileMode]::CreateNew
        $options.Access = [IO.FileAccess]::Write
        $options.Share = [IO.FileShare]::None
        $options.UnixCreateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        $stream = [IO.File]::Open($toolServerBodyPath, $options)
        try {
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            try {
                $writer.Write($toolServerBody)
            } finally {
                $writer.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    }
    az rest --method put --uri $toolServerUri --body "@$toolServerBodyPath" -o none
} finally {
    Remove-Item $toolServerBodyPath -Force -ErrorAction SilentlyContinue
}
$githubToken = $null
$githubAuthorization = $null
$toolServerBody = $null

$gatewayApiKey = ""
foreach ($operation in @("listSecrets", "listValues")) {
    try {
        $keyResult = az rest `
            --method post `
            --uri "https://management.azure.com${gatewayResourceId}/apiKeys/default/${operation}?api-version=$aiGatewayApiVersion" `
            --body "{}" `
            -o json | ConvertFrom-Json
        $gatewayApiKey = Get-FirstValue @(
            [string]$keyResult.primaryKey,
            [string]$keyResult.properties.primaryKey,
            [string]$keyResult.primaryValue,
            [string]$keyResult.properties.primaryValue
        )
        if (-not [string]::IsNullOrWhiteSpace($gatewayApiKey)) {
            break
        }
    } catch {
        continue
    }
}
if ([string]::IsNullOrWhiteSpace($gatewayApiKey)) {
    $gatewayApiKey = Get-FirstValue @(
        $env:AZURE_AI_GATEWAY_API_KEY,
        (Get-AzdValue "AZURE_AI_GATEWAY_API_KEY")
    )
}
$gatewayApiKey = Require-Value "AZURE_AI_GATEWAY_API_KEY" $gatewayApiKey

Test-GatewayModelRoute $gatewayUrl $gatewayModel $gatewayApiKey

azd env set AZURE_AI_GATEWAY_ENDPOINT $gatewayUrl
azd env set AZURE_AI_GATEWAY_MODEL $gatewayModel
azd env set AZURE_AI_GATEWAY_MINI_MODEL $gatewayMiniModel
azd env set GITHUB_REPOSITORY $githubRepository
azd env set AZURE_AI_GATEWAY_API_KEY $gatewayApiKey | Out-Null
azd env set TOOLBOX_NAME $toolboxName

Write-Host "Connecting Foundry Toolbox to the AI Gateway GitHub ToolServer."
azd ai connection create $toolboxConnectionName `
    --kind remote-tool `
    --target "$($gatewayUrl.TrimEnd('/'))/default/toolservers/github/mcp" `
    --auth-type custom-keys `
    --custom-key "Api-Key=$gatewayApiKey" `
    --force `
    --no-prompt `
    --project-endpoint $projectEndpoint `
    -o json | Out-Null

try {
    $toolbox = azd ai toolbox show $toolboxName `
        --no-prompt `
        --project-endpoint $projectEndpoint `
        -o json 2>$null | ConvertFrom-Json
} catch {
    Write-Host "Creating the Foundry Toolbox."
    $toolbox = azd ai toolbox create $toolboxName `
        --from-file (Join-Path $repoRoot "infra/toolbox.yaml") `
        --no-prompt `
        --project-endpoint $projectEndpoint `
        -o json | ConvertFrom-Json
}
azd env set TOOLBOX_ENDPOINT ([string]$toolbox.endpoint)

Remove-AzdEnvValues @(
    "AI_SERVICES_NAME",
    "MODEL_DEPLOYMENT_NAME",
    "AZURE_AI_MODEL_DEPLOYMENT_NAME",
    "GITHUB_MCP_TOKEN",
    "GITHUB_TOKEN",
    "FOUNDRY_API_KEY"
)

Write-Host "AI Gateway setup complete. Bicep owns Azure resources; this hook injects the GitHub credential, connects Foundry Toolbox to AI Gateway, and saves the runtime key."
