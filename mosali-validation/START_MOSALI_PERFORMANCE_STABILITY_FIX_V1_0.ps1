$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $Pwsh7 -PathType Leaf)) {
    throw "PowerShell 7 nicht gefunden: $Pwsh7"
}

$VersionText = & $Pwsh7 -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if (-not $VersionText -or -not ([version]$VersionText).Major -ge 7) {
    throw "PowerShell-7-Pruefung fehlgeschlagen. Gefunden=$VersionText"
}

$Name = 'MOSALI_PERFORMANCE_STABILITY_FIX_V1_0_20260824.zip'
$ExpectedZipSha = 'DEF01982B73CA871E43681F1784D742A95ACCD0F50CFB3358309EDE087BFDACF'
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

$ParserCheck = @'
param([Parameter(Mandatory=$true)][string]$Path)
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -ne 0) {
    $errors | Format-List | Out-String | Write-Host
    exit 41
}
exit 0
'@

$ParserCheckPath = Join-Path $Staging '_PS7_PARSE_CHECK.ps1'
[IO.File]::WriteAllText($ParserCheckPath, $ParserCheck, [Text.UTF8Encoding]::new($false))

& $Pwsh7 -NoProfile -File $ParserCheckPath -Path $Runner
if ($LASTEXITCODE -ne 0) {
    throw "PS7-PARSER_CHECK_FAILED ExitCode=$LASTEXITCODE"
}

Write-Host "ZIP + Manifest + nativer PS7-Parser: PASS | PowerShell $VersionText" -ForegroundColor Green

& $Pwsh7 -NoProfile -ExecutionPolicy Bypass -File $Runner
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
