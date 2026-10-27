#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("prepare", "cleanup")]
    [string]$Mode
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
if ([string]::IsNullOrWhiteSpace($Mode)) {
    throw "Usage: manage-ai-gateway-lifecycle.ps1 prepare|cleanup"
}
$aiGatewayApiVersion = "2025-09-01-preview"
$pollSeconds = [int]($env:APIM_LIFECYCLE_POLL_SECONDS ?? "10")
$identitySettleSeconds = [int]($env:APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS ?? "180")
$operationTimeoutSeconds = [int]($env:APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS ?? "900")

function Get-AzdValue([string]$Name) {
    try {
        return ([string](azd env get-value $Name 2>$null)).Trim()
    } catch {
        return ""
    }
}

function Get-FirstValue([string[]]$Values) {
    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value -ne "null") {
            return $value
        }
    }
    return ""
}

function Get-AzRestResult(
    [string]$Uri,
    [string]$Query = "",
    [string]$Output = "json"
) {
    $arguments = @("rest", "--method", "get", "--uri", $Uri, "-o", $Output)
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $arguments += @("--query", $Query)
    }

    $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $outputLines = @(& az @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    }

    $body = ($outputLines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($exitCode -eq 0) {
        return [pscustomobject]@{ Found = $true; Body = $body }
    }
    if ($body -match '(?im)(^ERROR:\s*(\((NotFound|ResourceNotFound)\)|(Not Found|NotFound|ResourceNotFound)([\s:({]|$))|"code"\s*:\s*"(NotFound|ResourceNotFound)"|"status(Code)?"\s*:\s*404)') {
        return [pscustomobject]@{ Found = $false; Body = "" }
    }
    throw "Azure REST GET failed for $Uri. $body"
}

function Find-FailedGateway {
    $groupPattern = '^rg-' + [regex]::Escape($environmentName.ToLowerInvariant()) + '-([a-z0-9]{8})-gateway$'
    $resourcePattern = '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.(ApiManagement/aigateways|Resources/deployments)/([^/]+)$'
    $candidates = @{}
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    function Find-InOperations($Operations, [int]$Depth) {
        foreach ($operation in $Operations) {
            $properties = $operation.properties
            if ($properties.provisioningState -ne "Failed") {
                continue
            }
            $target = $properties.targetResource
            $match = [regex]::Match([string]$target.id, $resourcePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $match.Success -or $match.Groups[1].Value -ne $subscriptionId) {
                continue
            }
            $group = $match.Groups[2].Value
            $resourceType = $match.Groups[3].Value
            $name = $match.Groups[4].Value
            $groupMatch = [regex]::Match($group, $groupPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not [string]::IsNullOrWhiteSpace($resourceGroup)) {
                if ($group -ne $resourceGroup) { continue }
            } elseif (-not $groupMatch.Success) {
                continue
            }

            if ($target.resourceType -eq "microsoft.resources/deployments" -and $resourceType -eq "Resources/deployments") {
                if (-not $visited.Contains($target.id)) {
                    if ($Depth -ge 3 -or $visited.Count -ge 30) {
                        throw "Failed deployment discovery exceeded its safe traversal limit."
                    }
                    $null = $visited.Add($target.id)
                    $nested = az deployment operation group list `
                        --subscription $subscriptionId `
                        --resource-group $group `
                        --name $name `
                        -o json | ConvertFrom-Json
                    Find-InOperations $nested ($Depth + 1)
                }
            } elseif ($target.resourceType -eq "microsoft.apimanagement/aigateways" -and $resourceType -eq "ApiManagement/aigateways") {
                $status = $properties.statusMessage | ConvertTo-Json -Depth 50 -Compress
                if ($status -notmatch '\b(FailedIdentityOperation|ActivationFailed)\b') {
                    continue
                }
                if (-not [string]::IsNullOrWhiteSpace($gatewayName)) {
                    if ($name -ne $gatewayName) { continue }
                } elseif (-not $groupMatch.Success -or $name -ne "aigw-$($groupMatch.Groups[1].Value)") {
                    continue
                }
                $candidates[([string]$target.id).ToLowerInvariant()] = [pscustomobject]@{ name = $name; resourceGroup = $group }
            }
        }
    }

    $deployments = az deployment sub list `
        --subscription $subscriptionId `
        --query "reverse(sort_by([?properties.provisioningState=='Failed'], &properties.timestamp))[:10]" `
        -o json | ConvertFrom-Json
    foreach ($deployment in $deployments) {
        if ($deployment.properties.provisioningState -eq "Failed") {
            $operations = az deployment operation sub list `
                --subscription $subscriptionId `
                --name $deployment.name `
                -o json | ConvertFrom-Json
            Find-InOperations $operations 0
        }
    }
    if ($candidates.Count -gt 1) {
        throw "Multiple AI Gateways found in failed deployments; set AI_GATEWAY_NAME and AI_GATEWAY_RESOURCE_GROUP."
    }
    foreach ($candidate in $candidates.Values) {
        $groupMetadata = az group show --subscription $subscriptionId --name $candidate.resourceGroup -o json | ConvertFrom-Json
        if ($groupMetadata.tags.'azd-env-name' -ne $environmentName) {
            throw "Refusing failed deployment resource group tagged for another or missing azd environment."
        }
        $candidate
    }
}

$environmentName = Get-FirstValue @($env:AZURE_ENV_NAME, (Get-AzdValue "AZURE_ENV_NAME"))
if ([string]::IsNullOrWhiteSpace($environmentName)) {
    throw "AZURE_ENV_NAME is required."
}

$subscriptionId = Get-FirstValue @(
    $env:AZURE_SUBSCRIPTION_ID,
    (Get-AzdValue "AZURE_SUBSCRIPTION_ID"),
    ([string](az account show --query id -o tsv 2>$null)).Trim()
)
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw "AZURE_SUBSCRIPTION_ID is required."
}

$resourceGroup = Get-FirstValue @(
    $env:AI_GATEWAY_RESOURCE_GROUP,
    (Get-AzdValue "AI_GATEWAY_RESOURCE_GROUP")
)
$gatewayName = Get-FirstValue @(
    $env:AI_GATEWAY_NAME,
    (Get-AzdValue "AI_GATEWAY_NAME")
)

if ([string]::IsNullOrWhiteSpace($resourceGroup) -or [string]::IsNullOrWhiteSpace($gatewayName)) {
    $candidates = @(
        az resource list `
            --subscription $subscriptionId `
            --resource-type Microsoft.ApiManagement/aigateways `
            --query "[?tags.`"azd-env-name`"=='$environmentName' && sku.name=='Consumption'].{name:name,resourceGroup:resourceGroup}" `
            -o json | ConvertFrom-Json
    )
    if ($candidates.Count -eq 0) {
        $candidates = @(Find-FailedGateway)
        if ($candidates.Count -eq 0) {
            Write-Host "No environment-owned AI Gateway requires lifecycle cleanup."
            exit 0
        }
    }
    if ($candidates.Count -ne 1) {
        throw "Multiple AI Gateways are tagged azd-env-name=$environmentName; set AI_GATEWAY_NAME and AI_GATEWAY_RESOURCE_GROUP."
    }
    $gatewayName = $candidates[0].name
    $resourceGroup = $candidates[0].resourceGroup
}

$resourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/aigateways/$gatewayName"
$resourceUri = "https://management.azure.com${resourceId}?api-version=$aiGatewayApiVersion"

$liveResult = Get-AzRestResult $resourceUri
$live = if ($liveResult.Found) { $liveResult.Body | ConvertFrom-Json } else { $null }

if ($null -ne $live) {
    if ($live.sku.name -ne "Consumption") {
        throw "Refusing resource with SKU $($live.sku.name)."
    }
    if ($live.tags.'azd-env-name' -ne $environmentName) {
        throw "Refusing resource tagged for azd environment $($live.tags.'azd-env-name')."
    }

    $state = [string]$live.properties.provisioningState
    if ($Mode -eq "prepare") {
        if ($state -eq "Succeeded") {
            Write-Host "Preserving healthy environment-owned AI Gateway $resourceGroup/$gatewayName."
            exit 0
        }
        if ($state -notin @("Failed", "Deleting")) {
            throw "The environment-owned AI Gateway is in nonterminal state $state; wait for Azure to finish or run azd down."
        }
    }

    if ($state -ne "Deleting") {
        Write-Host "Deleting environment-owned AI Gateway $resourceGroup/$gatewayName."
        az rest --method delete --uri $resourceUri --headers "If-Match=*" -o none
    }
}

$startedAt = [DateTimeOffset]::UtcNow
$quietStartedAt = $null
while ($true) {
    $now = [DateTimeOffset]::UtcNow
    if (($now - $startedAt).TotalSeconds -ge $operationTimeoutSeconds) {
        throw "Cleanup did not settle within ${operationTimeoutSeconds}s. Wait, then rerun azd provision."
    }

    $liveExists = (Get-AzRestResult $resourceUri).Found
    if ($liveExists) {
        $quietStartedAt = $null
        Write-Host "Waiting for AI Gateway deletion."
        Start-Sleep -Seconds $pollSeconds
        continue
    }

    if ($null -eq $quietStartedAt) {
        $quietStartedAt = $now
    }
    $quietElapsed = [int]($now - $quietStartedAt).TotalSeconds
    if ($quietElapsed -ge $identitySettleSeconds) {
        Write-Host "AI Gateway deletion and ${identitySettleSeconds}s identity settle window completed."
        exit 0
    }

    Write-Host "Waiting for managed-identity cleanup ($quietElapsed/$identitySettleSeconds seconds quiet)."
    Start-Sleep -Seconds $pollSeconds
}
