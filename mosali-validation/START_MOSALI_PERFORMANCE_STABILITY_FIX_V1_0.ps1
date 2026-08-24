$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 erforderlich. Aktuell: $($PSVersionTable.PSVersion)"
}

$Name = 'MOSALI_PERFORMANCE_STABILITY_FIX_V1_0_20260824.zip'
$ExpectedZipSha = 'EB1F396740003ABF79B22C9235F18A20FB3473AC8DAE70DBE0E24E5514AFD106'
$SearchRoots = @(
    (Join-Path $HOME 'Downloads'),
    (Join-Path $HOME 'Desktop'),
    $PWD.Path
) | Select-Object -Unique

$Zip = $null
foreach ($Root in $SearchRoots) {
    $Candidate = Join-Path $Root $Name
    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
        $Zip = $Candidate
        break
    }
}
if (-not $Zip) {
    throw "ZIP nicht gefunden: $Name"
}

$ActualZipSha = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToUpperInvariant()
if ($ActualZipSha -ne $ExpectedZipSha) {
    throw "ZIP-SHA256 stimmt nicht. Erwartet=$ExpectedZipSha Ist=$ActualZipSha"
}

$Staging = Join-Path $env:TEMP ('MOSALI_PERFORMANCE_STABILITY_FIX_V1_0_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $Staging -Force | Out-Null
Expand-Archive -LiteralPath $Zip -DestinationPath $Staging -Force

$Manifest = Join-Path $Staging 'MANIFEST.sha256'
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
    throw 'MANIFEST.sha256 fehlt.'
}
foreach ($Line in Get-Content -LiteralPath $Manifest) {
    if ($Line -notmatch '^([A-Fa-f0-9]{64})  (.+)$') {
        throw "Ungueltige Manifest-Zeile: $Line"
    }
    $Expected = $Matches[1].ToUpperInvariant()
    $Relative = $Matches[2] -replace '/', [IO.Path]::DirectorySeparatorChar
    $File = Join-Path $Staging $Relative
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        throw "Manifest-Datei fehlt: $Relative"
    }
    $Actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($Actual -ne $Expected) {
        throw "Manifest-SHA256 stimmt nicht: $Relative"
    }
}

$Runner = Join-Path $Staging 'RUN_MOSALI_PERFORMANCE_STABILITY_FIX_V1_0.ps1'
$Tokens = $null
$ParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Runner, [ref]$Tokens, [ref]$ParseErrors) | Out-Null
if ($ParseErrors.Count -ne 0) {
    $ParseErrors | Format-List | Out-String | Write-Host
    throw 'PS7-PARSER_CHECK_FAILED'
}

$Pwsh = (Get-Process -Id $PID).Path
if ([IO.Path]::GetFileName($Pwsh).ToLowerInvariant() -ne 'pwsh.exe') {
    throw "Dieser Block muss in PowerShell 7/pwsh.exe laufen. Aktuell=$Pwsh"
}

Write-Host 'ZIP + Manifest + PS7-Parser: PASS' -ForegroundColor Green
& $Pwsh -NoProfile -ExecutionPolicy Bypass -File $Runner
$ExitCode = $LASTEXITCODE
if ($ExitCode -ne 0) {
    throw "MOSALI Performance Stability Fix ExitCode=$ExitCode"
}

$Result = Get-ChildItem -LiteralPath (Join-Path $HOME 'Downloads') -File -Filter 'MOSALI_PERFORMANCE_STABILITY_FIX_V1_0_ERGEBNIS_*.zip' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($Result) {
    Write-Host "Ergebnis: $($Result.FullName)" -ForegroundColor Cyan
    Write-Host "SHA256:   $((Get-FileHash -LiteralPath $Result.FullName -Algorithm SHA256).Hash)" -ForegroundColor Cyan
}
