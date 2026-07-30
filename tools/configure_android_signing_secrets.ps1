param(
    [string]$Repository = "applenana/NextBananaThermalStudio"
)

$ErrorActionPreference = "Stop"

if ($Repository -notmatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") {
    throw "Invalid GitHub repository name: $Repository"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$keystorePath = Join-Path $repoRoot "android\app\release-keystore.jks"
$propertiesPath = Join-Path $repoRoot "android\key.properties"
if (-not (Test-Path -LiteralPath $keystorePath)) {
    throw "Keystore not found: $keystorePath"
}
if (-not (Test-Path -LiteralPath $propertiesPath)) {
    throw "Gradle signing properties not found: $propertiesPath"
}

$gh = (Get-Command gh -ErrorAction Stop).Source
& $gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI is not authenticated. Run: gh auth login"
}

$values = @{}
foreach ($line in [IO.File]::ReadAllLines($propertiesPath)) {
    $parts = $line.Split("=", 2)
    if ($parts.Count -eq 2) {
        $values[$parts[0].Trim()] = $parts[1].Trim()
    }
}

foreach ($requiredName in @("storePassword", "keyPassword", "keyAlias")) {
    if ([string]::IsNullOrWhiteSpace($values[$requiredName])) {
        throw "Missing '$requiredName' in $propertiesPath"
    }
}

$secrets = [ordered]@{
    "ANDROID_KEYSTORE_BASE64"   = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystorePath))
    "ANDROID_KEYSTORE_PASSWORD" = $values["storePassword"]
    "ANDROID_KEY_ALIAS"         = $values["keyAlias"]
    "ANDROID_KEY_PASSWORD"      = $values["keyPassword"]
}

foreach ($entry in $secrets.GetEnumerator()) {
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $gh
    $processInfo.Arguments = "secret set $($entry.Key) --repo $Repository"
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($processInfo)
    $process.StandardInput.Write($entry.Value)
    $process.StandardInput.Close()
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "Failed to upload GitHub secret '$($entry.Key)': $standardError$standardOutput"
    }
}

Write-Output "Android long-term signing secrets configured for $Repository."
