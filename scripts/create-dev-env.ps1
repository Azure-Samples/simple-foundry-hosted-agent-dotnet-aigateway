#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$outputPath = Join-Path (Get-Location) ".env"

if ((Test-Path $outputPath) -and -not $Force) {
    throw ".env already exists. Use -Force to replace it."
}

function Get-AzdValue($Name) {
    try {
        return ([string](azd env get-value $Name 2>$null)).Trim()
    } catch {
        return ""
    }
}

function Require-AzdValue($Name) {
    $value = Get-AzdValue $Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Name is missing. Run azd provision first."
    }
    return $value
}

function Quote-EnvValue($Value) {
    $escaped = ([string]$Value).Replace('\', '\\').Replace('"', '\"')
    return "`"$escaped`""
}

$endpoint = Require-AzdValue "AZURE_AI_GATEWAY_ENDPOINT"
$gatewayKey = Require-AzdValue "AZURE_AI_GATEWAY_API_KEY"
$model = Require-AzdValue "AZURE_AI_GATEWAY_MODEL"
$miniModel = Require-AzdValue "AZURE_AI_GATEWAY_MINI_MODEL"
$toolboxEndpoint = Require-AzdValue "TOOLBOX_ENDPOINT"
$toolboxName = Require-AzdValue "TOOLBOX_NAME"
$repository = Get-AzdValue "GITHUB_REPOSITORY"
if ([string]::IsNullOrWhiteSpace($repository)) {
    $repository = "microsoft/agent-framework"
}

$lines = @(
    "AZURE_AI_GATEWAY_ENDPOINT=$(Quote-EnvValue $endpoint)"
    "AZURE_AI_GATEWAY_API_KEY=$(Quote-EnvValue $gatewayKey)"
    "AZURE_AI_GATEWAY_MODEL=$(Quote-EnvValue $model)"
    "AZURE_AI_GATEWAY_MINI_MODEL=$(Quote-EnvValue $miniModel)"
    ""
    "TOOLBOX_ENDPOINT=$(Quote-EnvValue $toolboxEndpoint)"
    "TOOLBOX_NAME=$(Quote-EnvValue $toolboxName)"
    ""
    "GITHUB_REPOSITORY=$(Quote-EnvValue $repository)"
)

$tempPath = Join-Path (Get-Location) ".env.tmp.$([IO.Path]::GetRandomFileName())"
try {
    if ($IsWindows) {
        [IO.File]::WriteAllBytes($tempPath, [byte[]]::new(0))
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe $tempPath /inheritance:r /grant:r "${identity}:(R,W)" | Out-Null
    } else {
        $options = [IO.FileStreamOptions]::new()
        $options.Mode = [IO.FileMode]::CreateNew
        $options.Access = [IO.FileAccess]::Write
        $options.Share = [IO.FileShare]::None
        $options.UnixCreateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        [IO.File]::Open($tempPath, $options).Dispose()
    }

    [IO.File]::WriteAllText(
        $tempPath,
        ($lines -join [Environment]::NewLine) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    if ($Force) {
        Move-Item -Path $tempPath -Destination $outputPath -Force
    } else {
        Move-Item -Path $tempPath -Destination $outputPath
    }
    if ($IsWindows) {
        & icacls.exe $outputPath /inheritance:r /grant:r "${identity}:(R,W)" | Out-Null
    } else {
        [IO.File]::SetUnixFileMode(
            $outputPath,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        )
    }
} finally {
    Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Created .env for agent development: $outputPath"
