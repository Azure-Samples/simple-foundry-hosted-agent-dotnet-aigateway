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
$deletedServiceApiVersion = "2024-05-01"
$defaultLocation = "eastus2"
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
$gatewayLocation = (Get-FirstValue @(
    $env:AI_GATEWAY_LOCATION,
    (Get-AzdValue "AI_GATEWAY_LOCATION"),
    $defaultLocation
)).Replace(" ", "").ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($resourceGroup) -or [string]::IsNullOrWhiteSpace($gatewayName)) {
    $candidates = @(
        az resource list `
            --subscription $subscriptionId `
            --resource-type Microsoft.ApiManagement/service `
            --query "[?tags.`"azd-env-name`"=='$environmentName' && sku.name=='AIGateway'].{name:name,resourceGroup:resourceGroup,location:location}" `
            -o json | ConvertFrom-Json
    )
    if ($candidates.Count -eq 0) {
        Write-Host "No environment-owned AI Gateway requires lifecycle cleanup."
        exit 0
    }
    if ($candidates.Count -ne 1) {
        throw "Multiple AIGateway services are tagged azd-env-name=$environmentName; set AI_GATEWAY_NAME and AI_GATEWAY_RESOURCE_GROUP."
    }
    $gatewayName = $candidates[0].name
    $resourceGroup = $candidates[0].resourceGroup
    $gatewayLocation = ([string]$candidates[0].location).Replace(" ", "").ToLowerInvariant()
}

$resourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$gatewayName"
$resourceUri = "https://management.azure.com${resourceId}?api-version=$aiGatewayApiVersion"
$deletedUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.ApiManagement/locations/$gatewayLocation/deletedservices/${gatewayName}?api-version=$deletedServiceApiVersion"

$liveResult = Get-AzRestResult $resourceUri
$live = if ($liveResult.Found) { $liveResult.Body | ConvertFrom-Json } else { $null }

if ($null -ne $live) {
    if ($live.sku.name -ne "AIGateway") {
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

    $deletedResult = Get-AzRestResult $deletedUri "properties.serviceId" "tsv"
    $deletedServiceId = if ($deletedResult.Found) { $deletedResult.Body.Trim() } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($deletedServiceId)) {
        $quietStartedAt = $null
        if (-not $deletedServiceId.Equals($resourceId, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to purge soft-deleted AI Gateway because its serviceId does not match $resourceId."
        }
        Write-Host "Purging soft-deleted AI Gateway $gatewayName in $gatewayLocation."
        az rest --method delete --uri $deletedUri -o none
        Start-Sleep -Seconds $pollSeconds
        continue
    }

    if ($null -eq $quietStartedAt) {
        $quietStartedAt = $now
    }
    $quietElapsed = [int]($now - $quietStartedAt).TotalSeconds
    if ($quietElapsed -ge $identitySettleSeconds) {
        Write-Host "AI Gateway deletion, soft-delete purge, and ${identitySettleSeconds}s identity settle window completed."
        exit 0
    }

    Write-Host "Waiting for managed-identity cleanup ($quietElapsed/$identitySettleSeconds seconds quiet)."
    Start-Sleep -Seconds $pollSeconds
}
