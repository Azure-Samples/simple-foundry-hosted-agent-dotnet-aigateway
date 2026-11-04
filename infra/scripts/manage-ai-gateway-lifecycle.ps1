[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet("prepare", "cleanup")]
    [string]$Mode
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$aiGatewayApiVersion = "2025-09-01-preview"
$defaultAiGatewayLocation = "eastus2"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path

function Get-IntegerSetting($Name, $Default) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [string]$Default }
    $parsed = 0
    if (-not [int]::TryParse($value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or $parsed -lt 0) {
        throw "AI Gateway lifecycle error: $Name must be a nonnegative integer."
    }
    return $parsed
}

$pollInitialSeconds = Get-IntegerSetting "APIM_LIFECYCLE_POLL_INITIAL_SECONDS" 5
$pollMaxSeconds = Get-IntegerSetting "APIM_LIFECYCLE_POLL_MAX_SECONDS" 30
$identitySettleSeconds = Get-IntegerSetting "APIM_LIFECYCLE_IDENTITY_SETTLE_SECONDS" 180
$operationTimeoutSeconds = Get-IntegerSetting "APIM_LIFECYCLE_OPERATION_TIMEOUT_SECONDS" 900
$recentDeploymentLimit = Get-IntegerSetting "APIM_LIFECYCLE_RECENT_DEPLOYMENT_LIMIT" 10

function Get-AzdValue($Name) {
    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -eq 0) { return ([string]$value).Trim() }
    return ""
}

function First-Value([object[]]$Values) {
    foreach ($value in $Values) {
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text) -and $text -ne "null") {
            return $text.Trim()
        }
    }
    return ""
}

function ConvertTo-LocationName($Location) {
    return ([string]$Location).Replace(" ", "").ToLowerInvariant()
}

function Get-NowEpoch {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Get-NextDelay($Delay) {
    if ($Delay -eq 0 -or $Delay -ge $pollMaxSeconds) { return $pollMaxSeconds }
    return [Math]::Min($Delay * 2, $pollMaxSeconds)
}

function Get-MarkerValue($Name) {
    if (-not (Test-Path $stateFile)) { return "" }
    $prefix = "$Name="
    $match = Get-Content $stateFile | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } | Select-Object -Last 1
    if ($null -eq $match) { return "" }
    return $match.Substring($prefix.Length)
}

function ConvertTo-SafeMarkerValue($Value) {
    return ([string]$Value).Replace("`r", "").Replace("`n", "")
}

function Write-Marker($State, $ActionEpoch, $FailureId) {
    $directory = Split-Path -Parent $stateFile
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $lines = @(
        "version=1"
        "environment_name=$(ConvertTo-SafeMarkerValue $environmentName)"
        "subscription_id=$(ConvertTo-SafeMarkerValue $subscriptionId)"
        "resource_group=$(ConvertTo-SafeMarkerValue $resourceGroup)"
        "gateway_name=$(ConvertTo-SafeMarkerValue $gatewayName)"
        "location=$(ConvertTo-SafeMarkerValue $gatewayLocation)"
        "state=$(ConvertTo-SafeMarkerValue $State)"
        "action_epoch=$(ConvertTo-SafeMarkerValue $ActionEpoch)"
        "failure_id=$(ConvertTo-SafeMarkerValue $FailureId)"
    )
    $temporary = "$stateFile.tmp"
    Set-Content -Path $temporary -Value $lines -Encoding utf8NoBOM
    Move-Item -Path $temporary -Destination $stateFile -Force
}

function Test-NotFoundError($Text) {
    return $Text -match "(^|[^0-9])404([^0-9]|$)|ResourceNotFound|NotFound"
}

function Invoke-AzRestGet($Uri, $Query = "") {
    $errorFile = [IO.Path]::GetTempFileName()
    try {
        if ([string]::IsNullOrWhiteSpace($Query)) {
            $output = & az rest --method get --uri $Uri -o none 2>$errorFile
        } else {
            $output = & az rest --method get --uri $Uri --query $Query -o tsv 2>$errorFile
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return @{ Exists = $true; Output = ([string]($output | Out-String)).Trim() }
        }
        $errorText = Get-Content $errorFile -Raw -ErrorAction SilentlyContinue
        if (Test-NotFoundError $errorText) {
            return @{ Exists = $false; Output = "" }
        }
        throw "Azure REST GET failed for $Uri. $errorText"
    } finally {
        Remove-Item $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AzRestDelete($Uri, [switch]$RequireMatch) {
    $errorFile = [IO.Path]::GetTempFileName()
    try {
        if ($RequireMatch) {
            & az rest --method delete --uri $Uri --headers "If-Match=*" -o none 2>$errorFile | Out-Null
        } else {
            & az rest --method delete --uri $Uri -o none 2>$errorFile | Out-Null
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) { return }
        $errorText = Get-Content $errorFile -Raw -ErrorAction SilentlyContinue
        if (Test-NotFoundError $errorText) { return }
        throw "Azure REST DELETE failed for $Uri. $errorText"
    } finally {
        Remove-Item $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-DeterministicShape($CandidateName, $CandidateGroup) {
    $environmentLabel = $environmentName.ToLowerInvariant()
    return $CandidateName.StartsWith("aigw-", [StringComparison]::OrdinalIgnoreCase) -and
        $CandidateGroup.ToLowerInvariant().StartsWith("rg-$environmentLabel-", [StringComparison]::Ordinal) -and
        $CandidateGroup.EndsWith("-gateway", [StringComparison]::OrdinalIgnoreCase)
}

function Find-LiveGateway {
    $candidateLines = & az resource list `
        --subscription $subscriptionId `
        --resource-type Microsoft.ApiManagement/aigateways `
        --query "[?tags.`"azd-env-name`"=='$environmentName'].[name,resourceGroup,location]" `
        -o tsv
    if ($LASTEXITCODE -ne 0) {
        throw "AI Gateway lifecycle error: could not discover AI Gateway resources for azd environment $environmentName."
    }
    $candidates = @()
    foreach ($line in @($candidateLines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 3) { continue }
        if (-not (Test-DeterministicShape $parts[0] $parts[1])) {
            throw "AI Gateway lifecycle error: refusing the tagged AI Gateway $($parts[1])/$($parts[0]) because it does not match the deterministic environment naming shape."
        }
        $candidates += ,$parts
    }
    if ($candidates.Count -gt 1) {
        throw "AI Gateway lifecycle error: found multiple AI Gateways tagged azd-env-name=$environmentName; set AI_GATEWAY_NAME and AI_GATEWAY_RESOURCE_GROUP explicitly."
    }
    if ($candidates.Count -eq 0) { return $false }
    $script:gatewayName = $candidates[0][0]
    $script:resourceGroup = $candidates[0][1]
    $script:gatewayLocation = $candidates[0][2]
    return $true
}

function Find-RecentIdentityFailure {
    $script:recentFailureId = ""
    $deploymentLines = & az deployment sub list `
        --subscription $subscriptionId `
        --query "[?properties.provisioningState=='Failed'] | sort_by(@, &properties.timestamp) | reverse(@)[:$recentDeploymentLimit].name" `
        -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "AI Gateway lifecycle error: could not inspect recent subscription deployment failures for managed-identity recovery."
    }
    foreach ($deploymentName in @($deploymentLines)) {
        if ([string]::IsNullOrWhiteSpace($deploymentName)) { continue }
        $operationTargetLines = & az deployment operation sub list `
            --subscription $subscriptionId `
            --name $deploymentName `
            --query "[?contains(to_string(properties.statusMessage), 'FailedIdentityOperation') || contains(to_string(properties.statusMessage), 'ActivationFailed')].properties.targetResource.id" `
            -o tsv 2>$null
        foreach ($targetId in @($operationTargetLines)) {
            if ([string]::IsNullOrWhiteSpace($targetId) -or $targetId -eq "null") { continue }
            $segments = $targetId.Trim("/") -split "/"
            if ($segments.Count -lt 8) { continue }
            $targetGroup = $segments[3]
            $targetProvider = $segments[5]
            $targetType = $segments[6]
            $targetName = $segments[7]
            if ($targetProvider -eq "Microsoft.Resources" -and $targetType -eq "deployments") {
                $nestedTargetLines = & az deployment operation group list `
                    --subscription $subscriptionId `
                    --resource-group $targetGroup `
                    --name $targetName `
                    --query "[?contains(to_string(properties.statusMessage), 'FailedIdentityOperation') || contains(to_string(properties.statusMessage), 'ActivationFailed')].properties.targetResource.id" `
                    -o tsv 2>$null
                foreach ($nestedTargetId in @($nestedTargetLines)) {
                    if (Use-FailureTarget $nestedTargetId "${deploymentName}:${targetId}") { return $true }
                }
            } elseif (Use-FailureTarget $targetId $deploymentName) {
                return $true
            }
        }
    }
    return $false
}

function Use-FailureTarget($TargetId, $DeploymentId) {
    if ([string]::IsNullOrWhiteSpace($TargetId) -or $TargetId -eq "null") { return $false }
    $segments = $TargetId.Trim("/") -split "/"
    if ($segments.Count -lt 8) { return $false }
    $targetSubscription = $segments[1]
    $targetGroup = $segments[3]
    $targetProvider = $segments[5]
    $targetType = $segments[6]
    $targetName = $segments[7]
    if ($targetSubscription -ne $subscriptionId -or
        $targetProvider -ne "Microsoft.ApiManagement" -or
        $targetType -ne "aigateways" -or
        -not (Test-DeterministicShape $targetName $targetGroup)) {
        return $false
    }
    $groupOwner = [string](& az group show `
        --subscription $subscriptionId `
        --name $targetGroup `
        --query "tags.`"azd-env-name`"" `
        -o tsv 2>$null)
    $groupLookupSucceeded = $LASTEXITCODE -eq 0
    if ($groupLookupSucceeded -and
        -not [string]::IsNullOrWhiteSpace($groupOwner) -and
        $groupOwner -ne "null" -and
        $groupOwner -ne $environmentName) {
        throw "AI Gateway lifecycle error: refusing identity recovery for $targetGroup/$targetName; its resource group is tagged for azd environment $groupOwner."
    }
    if (-not $groupLookupSucceeded -or $groupOwner -ne $environmentName) {
        return $false
    }
    $script:gatewayName = $targetName
    $script:resourceGroup = $targetGroup
    $script:recentFailureId = "${DeploymentId}:${TargetId}"
    return $true
}

function Update-ResourceUris {
    $script:serviceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/aigateways/$gatewayName"
    $script:serviceUri = "https://management.azure.com${serviceResourceId}?api-version=$aiGatewayApiVersion"
}

function Get-LiveRecord {
    $result = Invoke-AzRestGet $serviceUri "join('|', [to_string(properties.provisioningState), to_string(sku.name), to_string(tags.`"azd-env-name`"), to_string(location), to_string(properties.targetProvisioningState)])"
    if (-not $result.Exists) { return $null }
    $parts = $result.Output -split "\|", 5
    if ($parts.Count -lt 5) {
        throw "AI Gateway lifecycle error: Azure returned an incomplete record for $resourceGroup/$gatewayName."
    }
    return @{
        State = $parts[0].Trim('"')
        Sku = $parts[1].Trim('"')
        Owner = $parts[2].Trim('"')
        Location = $parts[3].Trim('"')
        TargetState = $parts[4].Trim('"')
    }
}

function Test-LiveDeleting($Record) {
    return $Record.State -eq "Deleting" -or $Record.TargetState -eq "Deleting"
}

function Assert-LiveOwnership($Record) {
    if ($Record.Owner -ne $environmentName) {
        throw "AI Gateway lifecycle error: refusing $resourceGroup/$gatewayName; expected azd-env-name=$environmentName but found $($Record.Owner)."
    }
    if (-not [string]::IsNullOrWhiteSpace($Record.Location) -and $Record.Location -ne "null") {
        $script:gatewayLocation = ConvertTo-LocationName $Record.Location
        Update-ResourceUris
    }
}

function Remove-LiveGateway($Action) {
    Write-Host "$Action environment-owned AI Gateway $resourceGroup/$gatewayName."
    Invoke-AzRestDelete $serviceUri -RequireMatch
}

function Wait-GatewaySettle($QuietStart, $FailureId) {
    $startedAt = Get-NowEpoch
    $delay = $pollInitialSeconds
    while ($true) {
        $surfacesClear = $true
        $record = Get-LiveRecord
        if ($null -ne $record) {
            Assert-LiveOwnership $record
            $surfacesClear = $false
            $QuietStart = Get-NowEpoch
            if (Test-LiveDeleting $record) {
                Write-Host "Waiting for AI Gateway $gatewayName to finish deleting."
            } elseif ($Mode -eq "prepare" -and $record.State -ne "Failed") {
                throw "AI Gateway lifecycle error: the expected AI Gateway reappeared in nonterminal state $($record.State); wait for Azure to finish or run an explicit azd down before retrying."
            } else {
                Remove-LiveGateway "Deleting"
            }
        }

        $current = Get-NowEpoch
        $elapsed = $current - $QuietStart
        if ($surfacesClear -and $elapsed -ge $identitySettleSeconds) {
            Write-Marker "settled" $current $FailureId
            Write-Host "AI Gateway deletion and ${identitySettleSeconds}s identity settle window completed."
            return
        }
        if (($current - $startedAt) -ge $operationTimeoutSeconds) {
            Write-Marker "pending" $QuietStart $FailureId
            throw "AI Gateway lifecycle error: cleanup did not remain quiet for ${identitySettleSeconds}s within the ${operationTimeoutSeconds}s bound. Wait, then rerun 'azd provision'. If FailedIdentityOperation persists, run 'azd down' and retry 'azd up'."
        }
        Write-Host "Waiting for AI Gateway deletion and managed-identity cleanup ($elapsed/${identitySettleSeconds}s quiet)."
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        $delay = Get-NextDelay $delay
    }
}

$environmentName = First-Value @($env:AZURE_ENV_NAME, (Get-AzdValue "AZURE_ENV_NAME"))
if ([string]::IsNullOrWhiteSpace($environmentName)) {
    throw "AI Gateway lifecycle error: AZURE_ENV_NAME is required."
}

if (-not [string]::IsNullOrWhiteSpace($env:APIM_LIFECYCLE_STATE_FILE)) {
    $stateFile = $env:APIM_LIFECYCLE_STATE_FILE
} elseif (-not [string]::IsNullOrWhiteSpace($env:AZD_ENV_FILE)) {
    $stateFile = Join-Path (Split-Path -Parent $env:AZD_ENV_FILE) "apim-lifecycle.state"
} else {
    $stateFile = Join-Path $repoRoot ".azure/$environmentName/apim-lifecycle.state"
}

$markerEnvironmentName = Get-MarkerValue "environment_name"
if (-not [string]::IsNullOrWhiteSpace($markerEnvironmentName) -and $markerEnvironmentName -ne $environmentName) {
    throw "AI Gateway lifecycle error: the lifecycle marker belongs to azd environment $markerEnvironmentName, not $environmentName."
}

$accountSubscription = [string](& az account show --query id -o tsv 2>$null)
if ($LASTEXITCODE -ne 0) { $accountSubscription = "" }
$subscriptionId = First-Value @(
    $env:AZURE_SUBSCRIPTION_ID,
    (Get-AzdValue "AZURE_SUBSCRIPTION_ID"),
    (Get-MarkerValue "subscription_id"),
    $accountSubscription
)
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw "AI Gateway lifecycle error: AZURE_SUBSCRIPTION_ID is required."
}

$resourceGroup = First-Value @(
    $env:AI_GATEWAY_RESOURCE_GROUP,
    (Get-AzdValue "AI_GATEWAY_RESOURCE_GROUP"),
    (Get-MarkerValue "resource_group")
)
$gatewayName = First-Value @(
    $env:AI_GATEWAY_NAME,
    (Get-AzdValue "AI_GATEWAY_NAME"),
    (Get-MarkerValue "gateway_name")
)
$gatewayLocation = First-Value @(
    $env:AI_GATEWAY_LOCATION,
    (Get-AzdValue "AI_GATEWAY_LOCATION"),
    (Get-MarkerValue "location"),
    $defaultAiGatewayLocation
)
$gatewayLocation = ConvertTo-LocationName $gatewayLocation
$markerState = Get-MarkerValue "state"
$markerActionEpoch = Get-MarkerValue "action_epoch"
$markerFailureId = Get-MarkerValue "failure_id"
$recentFailureId = ""

if ([string]::IsNullOrWhiteSpace($resourceGroup) -or [string]::IsNullOrWhiteSpace($gatewayName)) {
    if (-not (Find-LiveGateway) -and -not (Find-RecentIdentityFailure)) {
        if ($Mode -eq "cleanup") {
            Write-Host "No existing or recently failed AI Gateway belongs to azd environment $environmentName; no lifecycle cleanup is needed."
            return
        }
        Write-Host "No existing or recently failed AI Gateway belongs to azd environment $environmentName; no lifecycle cleanup is needed."
        return
    }
}

if ([string]::IsNullOrWhiteSpace($resourceGroup) -or [string]::IsNullOrWhiteSpace($gatewayName)) {
    throw "AI Gateway lifecycle error: both AI_GATEWAY_RESOURCE_GROUP and AI_GATEWAY_NAME are required once a lifecycle candidate is found."
}

$gatewayLocation = ConvertTo-LocationName $gatewayLocation
Update-ResourceUris
$record = Get-LiveRecord
if ($null -ne $record) { Assert-LiveOwnership $record }

if ($null -ne $record) {
    if ($Mode -eq "prepare") {
        switch ($record.State) {
            "Succeeded" {
                if (Test-LiveDeleting $record) {
                    $quietStart = Get-NowEpoch
                    Write-Marker "pending" $quietStart $markerFailureId
                    Write-Host "Waiting for environment-owned AI Gateway $resourceGroup/$gatewayName to finish deleting."
                } else {
                    Write-Marker "ready" (Get-NowEpoch) $markerFailureId
                    Write-Host "Preserving healthy environment-owned AI Gateway $resourceGroup/$gatewayName."
                    return
                }
            }
            "Failed" {
                $quietStart = Get-NowEpoch
                Write-Marker "pending" $quietStart $markerFailureId
                Remove-LiveGateway "Recovering terminal-Failed"
            }
            default {
                throw "AI Gateway lifecycle error: the environment-owned AI Gateway is in nonterminal state $($record.State); it will not be deleted automatically. Wait for Azure to finish or run an explicit azd down."
            }
        }
    } else {
        $quietStart = Get-NowEpoch
        Write-Marker "pending" $quietStart $markerFailureId
        if (Test-LiveDeleting $record) {
            Write-Host "Waiting for environment-owned AI Gateway $resourceGroup/$gatewayName to finish deleting."
        } else {
            Remove-LiveGateway "Deleting"
        }
    }
} else {
    if ($Mode -eq "cleanup") {
        $quietStart = Get-NowEpoch
    } elseif ($markerState -eq "pending" -and -not [string]::IsNullOrWhiteSpace($markerActionEpoch)) {
        $quietStart = [long]$markerActionEpoch
    } elseif ($markerState -eq "settled") {
        if ((Find-RecentIdentityFailure) -and $recentFailureId -ne $markerFailureId) {
            Update-ResourceUris
            $quietStart = Get-NowEpoch
        } else {
            Write-Host "Previous AI Gateway cleanup is already settled; no lifecycle wait is needed."
            return
        }
    } else {
        $quietStart = Get-NowEpoch
    }
    Write-Marker "pending" $quietStart (First-Value @($recentFailureId, $markerFailureId))
}

Wait-GatewaySettle $quietStart (First-Value @($recentFailureId, $markerFailureId))
