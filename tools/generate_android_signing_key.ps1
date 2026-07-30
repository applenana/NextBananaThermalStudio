param(
    [string]$BackupDirectory = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$keystorePath = Join-Path $repoRoot "android\app\release-keystore.jks"
$propertiesPath = Join-Path $repoRoot "android\key.properties"
if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    $BackupDirectory = "$repoRoot-signing-backup"
}

$backupKeystore = Join-Path $BackupDirectory "banana-thermal-release.jks"
$certificatePath = Join-Path $BackupDirectory "banana-thermal-release-certificate.pem"
$recoveryPath = Join-Path $BackupDirectory "SIGNING-RECOVERY.txt"

foreach ($path in @(
    $keystorePath,
    $propertiesPath,
    $backupKeystore,
    $certificatePath,
    $recoveryPath
)) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite an existing signing file: $path"
    }
}

$keytool = (Get-Command keytool -ErrorAction Stop).Source
$randomBytes = New-Object byte[] 32
$random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $random.GetBytes($randomBytes)
} finally {
    $random.Dispose()
}
$password = ([BitConverter]::ToString($randomBytes)).Replace("-", "").ToLowerInvariant()
$alias = "banana_thermal"

New-Item -ItemType Directory -Path (Split-Path $keystorePath) -Force | Out-Null
New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null

& $keytool `
    -genkeypair `
    -keystore $keystorePath `
    -storetype PKCS12 `
    -storepass $password `
    -keypass $password `
    -alias $alias `
    -keyalg RSA `
    -keysize 4096 `
    -validity 10000 `
    -dname "CN=BananaThermal Studio, OU=Software, O=applenana, L=Unknown, ST=Unknown, C=CN"
if ($LASTEXITCODE -ne 0) {
    throw "keytool failed to generate the signing key (exit code $LASTEXITCODE)."
}

$properties = @"
storePassword=$password
keyPassword=$password
keyAlias=$alias
storeFile=release-keystore.jks
"@
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($propertiesPath, $properties, $utf8NoBom)
Copy-Item -LiteralPath $keystorePath -Destination $backupKeystore

& $keytool `
    -exportcert `
    -rfc `
    -keystore $keystorePath `
    -storepass $password `
    -alias $alias `
    -file $certificatePath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "keytool failed to export the public certificate (exit code $LASTEXITCODE)."
}

$fingerprintLine = (& $keytool `
    -list `
    -v `
    -keystore $keystorePath `
    -storepass $password `
    -alias $alias | Select-String "SHA256:").Line.Trim()

$recovery = @"
BananaThermal Studio Android release signing recovery
=====================================================

Keystore file: banana-thermal-release.jks
Store type: PKCS12
Key alias: $alias
Store password: $password
Key password: $password
Validity: 10000 days
$fingerprintLine

IMPORTANT:
1. Keep this directory offline in at least two secure backup locations.
2. Never commit the keystore or this recovery file to Git.
3. Losing this key prevents existing Android installations from receiving updates.
"@
[IO.File]::WriteAllText($recoveryPath, $recovery, $utf8NoBom)

Write-Output "Android long-term signing key generated."
Write-Output "Local keystore: $keystorePath"
Write-Output "Local Gradle config: $propertiesPath"
Write-Output "Independent recovery backup: $BackupDirectory"
Write-Output "Certificate fingerprint: $fingerprintLine"
Write-Output "Passwords were not printed. Read them only from the recovery file and keep offline backups."
