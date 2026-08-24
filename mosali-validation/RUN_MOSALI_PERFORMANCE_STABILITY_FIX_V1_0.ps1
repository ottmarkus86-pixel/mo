[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Version = 'PERFORMANCE-STABILITY-FIX-V1.0'
$ProjectRoot = 'D:\SalesOS-KI\Projekte\KI-Agent'
$App = Join-Path $ProjectRoot 'App_v2_DEV2'
$HermesRoot = Join-Path $ProjectRoot 'Hermes_Beta_DEV'
$HermesCore = Join-Path $HermesRoot 'runtime\hermes_dev_core.py'
$Backend = Join-Path $App 'backend.py'
$Wake = Join-Path $App 'runtime\wake\Simon_Wake_Listener.py'
$WakeStart = Join-Path $App 'runtime\wake\Start_Wake_Listener.vbs'
$StartupController = Join-Path $ProjectRoot 'operations\mosali_server_startup_controller\Invoke-MOSALIServerStartupController.ps1'
$Payload = Join-Path $PSScriptRoot 'payload'
$Downloads = Join-Path $HOME 'Downloads'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Evidence = Join-Path $Downloads ("MOSALI_PERFORMANCE_STABILITY_FIX_V1_0_ERGEBNIS_{0}" -f $Stamp)
$ResultZip = "$Evidence.zip"
$BackupRoot = Join-Path $ProjectRoot ("Sicherungen\PERFORMANCE_STABILITY_FIX_V1_0_{0}" -f $Stamp)
$CandidateRoot = Join-Path $env:TEMP ("MOSALI_PERF_FIX_CANDIDATE_{0}" -f $Stamp)
$VoiceResident = Join-Path $App 'runtime\voice_resident'
$GuardDir = Join-Path $ProjectRoot 'operations\mosali_performance_guard'
$MutationStarted = $false
$GuardPid = $null

function Step([int]$N,[int]$Total,[string]$Text) {
    $pct=[math]::Floor((($N-1)/[double]$Total)*100)
    Write-Progress -Id 1 -Activity 'MOSALI Performance Stability Fix V1.0' -Status ("Schritt {0}/{1}: {2}" -f $N,$Total,$Text) -PercentComplete $pct
    Write-Host ("[{0}/{1}] {2}" -f $N,$Total,$Text) -ForegroundColor Cyan
}
function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function JsonFile($Obj,[string]$Path) { $Obj | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Get-OneListener([int]$Port) {
    $x=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if($x.Count -ne 1){ throw "Port $Port ListenerCount=$($x.Count), erwartet 1." }
    return $x[0]
}
function Proc([int]$ProcessId) { Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction Stop }
function ConsolePython([string]$Exe) {
    $p=[System.IO.Path]::GetFullPath($Exe)
    if([System.IO.Path]::GetFileName($p).ToLowerInvariant() -eq 'pythonw.exe') {
        $c=Join-Path ([System.IO.Path]::GetDirectoryName($p)) 'python.exe'
        if(Test-Path -LiteralPath $c -PathType Leaf){ return $c }
    }
    return $p
}
function Test-Json([string]$Uri,[string]$Service='') {
    try {
        $v=Invoke-RestMethod -Uri $Uri -TimeoutSec 5
        if($Service -and [string]$v.service -ne $Service){ return $false }
        if($v.PSObject.Properties.Name -contains 'status' -and [string]$v.status -notin @('READY','ok','OK')) { return $false }
        return $true
    } catch { return $false }
}
function Wait-Json([string]$Uri,[string]$Service,[int]$Seconds=90) {
    $deadline=(Get-Date).AddSeconds($Seconds)
    do { if(Test-Json $Uri $Service){return}; Start-Sleep -Milliseconds 500 } while((Get-Date)-lt $deadline)
    throw "Timeout: $Service nicht READY: $Uri"
}
function Stop-Port([int]$Port) {
    $ls=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    foreach($l in $ls){ Stop-Process -Id ([int]$l.OwningProcess) -Force -ErrorAction Stop }
    $deadline=(Get-Date).AddSeconds(20)
    do { if(@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue).Count -eq 0){return}; Start-Sleep -Milliseconds 300 } while((Get-Date)-lt $deadline)
    throw "Port $Port wurde nicht frei."
}
function Stop-WakeProcesses {
    $escaped=[regex]::Escape($Wake)
    $ps=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match $escaped })
    foreach($p in $ps){ Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue }
}
function Start-ExistingWake {
    if(-not(Test-Path -LiteralPath $WakeStart -PathType Leaf)){ throw "Wake-Starter fehlt: $WakeStart" }
    Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList ('"{0}"' -f $WakeStart) -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 3
}
function WakeCount {
    $escaped=[regex]::Escape($Wake)
    @((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match $escaped })).Count
}
function Start-StartupController {
    if(-not(Test-Path -LiteralPath $StartupController -PathType Leaf)){ throw "Startup Controller fehlt: $StartupController" }
    $pwsh=(Get-Process -Id $PID).Path
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $StartupController
    if($LASTEXITCODE -ne 0){ throw "Startup Controller ExitCode=$LASTEXITCODE" }
}
function Start-Daemon([string]$Python,[string]$Script,[int]$Port,[string]$Service) {
    if(Test-Json ("http://127.0.0.1:{0}/health" -f $Port) $Service){ return }
    if(@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue).Count -gt 0){ throw "Port $Port ist durch fremden Dienst belegt." }
    $pyw=Join-Path ([System.IO.Path]::GetDirectoryName($Python)) 'pythonw.exe'; if(-not(Test-Path -LiteralPath $pyw)){ $pyw=$Python }
    Start-Process -FilePath $pyw -ArgumentList ('"{0}"' -f $Script) -WorkingDirectory $App -WindowStyle Hidden | Out-Null
    Wait-Json ("http://127.0.0.1:{0}/health" -f $Port) $Service 90
}
function Make-Result([string]$Status,[string]$ErrorText='') {
    $summary=[ordered]@{status=$Status;version=$Version;time=(Get-Date).ToString('o');backup=$BackupRoot;error=$ErrorText}
    JsonFile $summary (Join-Path $Evidence 'SUMMARY.json')
    if(Test-Path -LiteralPath $ResultZip){Remove-Item -LiteralPath $ResultZip -Force}
    Compress-Archive -Path (Join-Path $Evidence '*') -DestinationPath $ResultZip -Force
    Write-Host "Ergebnis-ZIP: $ResultZip" -ForegroundColor Yellow
    Write-Host "ZIP-SHA256: $(Sha $ResultZip)" -ForegroundColor Yellow
}
function Restore-IfExists([string]$Backup,[string]$Live) {
    if(Test-Path -LiteralPath $Backup -PathType Leaf){ Copy-Item -LiteralPath $Backup -Destination $Live -Force }
}
function Rollback([string]$Reason) {
    Write-Host "ROLLBACK: $Reason" -ForegroundColor Yellow
    try { Stop-Port 17868 } catch {}
    try { Stop-Port 17869 } catch {}
    try { Stop-Port 17861 } catch {}
    try { Stop-Port 17865 } catch {}
    try { Stop-WakeProcesses } catch {}
    Restore-IfExists (Join-Path $BackupRoot 'backend.py') $Backend
    Restore-IfExists (Join-Path $BackupRoot 'Simon_Wake_Listener.py') $Wake
    Restore-IfExists (Join-Path $BackupRoot 'hermes_dev_core.py') $HermesCore
    if(Test-Path -LiteralPath (Join-Path $BackupRoot 'voice_resident') -PathType Container) {
        if(Test-Path -LiteralPath $VoiceResident){Remove-Item -LiteralPath $VoiceResident -Recurse -Force}
        Copy-Item -LiteralPath (Join-Path $BackupRoot 'voice_resident') -Destination $VoiceResident -Recurse -Force
    } elseif(Test-Path -LiteralPath $VoiceResident) { Remove-Item -LiteralPath $VoiceResident -Recurse -Force }
    if($GuardPid){ try{Stop-Process -Id $GuardPid -Force -ErrorAction SilentlyContinue}catch{} }
    try { Start-StartupController; Start-ExistingWake } catch {}
}

New-Item -ItemType Directory -Path $Evidence,$BackupRoot,$CandidateRoot -Force | Out-Null
try {
    Step 1 9 'Host, PowerShell 7 und aktuelle Runtime pruefen'
    if($PSVersionTable.PSVersion.Major -lt 7){ throw 'PowerShell 7 erforderlich.' }
    if($env:COMPUTERNAME -ne 'NICEATHOME'){ throw "Nur NICEATHOME erlaubt. Host=$env:COMPUTERNAME" }
    foreach($p in @($Backend,$Wake,$HermesCore,$StartupController)){ if(-not(Test-Path -LiteralPath $p -PathType Leaf)){ throw "Datei fehlt: $p" } }
    $model=Get-OneListener 1235; $simon=Get-OneListener 17861; $hermes=Get-OneListener 17865; $dash=Get-OneListener 17864
    if(-not(Test-Json 'http://127.0.0.1:17861/api/status')){throw 'Simon 17861 nicht READY.'}
    if(-not(Test-Json 'http://127.0.0.1:17865/v1/execution/capabilities')){throw 'Hermes 17865 nicht READY.'}
    $simonProc=Proc ([int]$simon.OwningProcess); $hermesProc=Proc ([int]$hermes.OwningProcess)
    $SimonPython=ConsolePython ([string]$simonProc.ExecutablePath); $HermesPython=ConsolePython ([string]$hermesProc.ExecutablePath)
    JsonFile ([ordered]@{ps=$PSVersionTable.PSVersion.ToString();model_pid=$model.OwningProcess;simon_pid=$simon.OwningProcess;hermes_pid=$hermes.OwningProcess;dashboard_pid=$dash.OwningProcess;simon_python=$SimonPython;hermes_python=$HermesPython;wake_count=(WakeCount);hashes=@{backend=(Sha $Backend);wake=(Sha $Wake);hermes=(Sha $HermesCore)}}) (Join-Path $Evidence '01_PRECHECK.json')

    Step 2 9 'Payload, Python und Zielruntimes pruefen'
    foreach($p in @('patch_performance_fix.py','mosali_stt_daemon.py','mosali_tts_daemon.py','mosali_peak_guard.py')){ if(-not(Test-Path -LiteralPath (Join-Path $Payload $p) -PathType Leaf)){throw "Payload fehlt: $p"} }
    $VoicePy=Join-Path $App 'runtime\voice-venv\Scripts\python.exe'; $TtsPy=Join-Path $App 'runtime\tts-kokoro-venv\Scripts\python.exe'
    foreach($p in @($VoicePy,$TtsPy,$SimonPython,$HermesPython)){ if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Python fehlt: $p"} }
    foreach($p in Get-ChildItem -LiteralPath $Payload -Filter '*.py' -File){ & $HermesPython -m py_compile $p.FullName; if($LASTEXITCODE -ne 0){throw "Payload py_compile FAIL: $($p.Name)"} }

    Step 3 9 'Fresh-Read Kandidaten erzeugen und kompilieren'
    & $HermesPython (Join-Path $Payload 'patch_performance_fix.py') --backend $Backend --wake $Wake --hermes $HermesCore --out $CandidateRoot
    if($LASTEXITCODE -ne 0){throw "Patcher ExitCode=$LASTEXITCODE"}
    foreach($pair in @(@($SimonPython,(Join-Path $CandidateRoot 'backend.py')),@($VoicePy,(Join-Path $CandidateRoot 'Simon_Wake_Listener.py')),@($HermesPython,(Join-Path $CandidateRoot 'hermes_dev_core.py')))){
        & $pair[0] -m py_compile $pair[1]; if($LASTEXITCODE -ne 0){throw "Candidate py_compile FAIL: $($pair[1])"}
    }
    Copy-Item -LiteralPath (Join-Path $CandidateRoot 'PATCH_REPORT.json') -Destination (Join-Path $Evidence '02_PATCH_REPORT.json') -Force

    Step 4 9 'Backup und Scope-Gate'
    Copy-Item -LiteralPath $Backend -Destination (Join-Path $BackupRoot 'backend.py') -Force
    Copy-Item -LiteralPath $Wake -Destination (Join-Path $BackupRoot 'Simon_Wake_Listener.py') -Force
    Copy-Item -LiteralPath $HermesCore -Destination (Join-Path $BackupRoot 'hermes_dev_core.py') -Force
    if(Test-Path -LiteralPath $VoiceResident -PathType Container){ Copy-Item -LiteralPath $VoiceResident -Destination (Join-Path $BackupRoot 'voice_resident') -Recurse -Force }
    foreach($n in @('backend.py','Simon_Wake_Listener.py','hermes_dev_core.py')){ if((Sha (Join-Path $BackupRoot $n)) -ne (Sha $(if($n -eq 'backend.py'){$Backend}elseif($n -eq 'Simon_Wake_Listener.py'){$Wake}else{$HermesCore}))){throw "Backup SHA FAIL: $n"} }
    $MutationStarted=$true

    Step 5 9 'Resident Voice, Wake-CPU-Cap und Hermes-Lastschranke installieren'
    New-Item -ItemType Directory -Path $VoiceResident -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Payload 'mosali_stt_daemon.py') -Destination (Join-Path $VoiceResident 'mosali_stt_daemon.py') -Force
    Copy-Item -LiteralPath (Join-Path $Payload 'mosali_tts_daemon.py') -Destination (Join-Path $VoiceResident 'mosali_tts_daemon.py') -Force
    Copy-Item -LiteralPath (Join-Path $CandidateRoot 'backend.py') -Destination $Backend -Force
    Copy-Item -LiteralPath (Join-Path $CandidateRoot 'Simon_Wake_Listener.py') -Destination $Wake -Force
    Copy-Item -LiteralPath (Join-Path $CandidateRoot 'hermes_dev_core.py') -Destination $HermesCore -Force

    Step 6 9 'Nur Simon, Hermes und Wake kontrolliert neu laden'
    Stop-WakeProcesses; Stop-Port 17861; Stop-Port 17865
    Start-StartupController
    Wait-Json 'http://127.0.0.1:17861/api/status' '' 120
    Wait-Json 'http://127.0.0.1:17865/v1/execution/capabilities' '' 120
    Start-ExistingWake

    Step 7 9 'Resident STT/TTS starten und Regression pruefen'
    Start-Daemon $VoicePy (Join-Path $VoiceResident 'mosali_stt_daemon.py') 17868 'MOSALI_STT_RESIDENT'
    Start-Daemon $TtsPy (Join-Path $VoiceResident 'mosali_tts_daemon.py') 17869 'MOSALI_TTS_RESIDENT'
    $ttsReq=@{text='Simon Leistungstest.'}|ConvertTo-Json -Compress
    $tts=Invoke-RestMethod -Uri 'http://127.0.0.1:17869/tts' -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($ttsReq)) -TimeoutSec 120
    if([string]$tts.status -ne 'OK' -or -not(Test-Path -LiteralPath ([string]$tts.path) -PathType Leaf)){throw 'TTS Resident Regression fehlgeschlagen.'}
    if((WakeCount) -ne 1){throw "Wake Listener Count nach Fix !=1: $(WakeCount)"}
    $backendRootCount=@((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {$_.CommandLine -and $_.CommandLine -match [regex]::Escape($Backend)})).Count
    if($backendRootCount -ne 1){throw "Backend Prozess Count !=1: $backendRootCount"}

    Step 8 9 'Peak-Waechter installieren und starten'
    if(-not(Test-Path -LiteralPath $GuardDir -PathType Container)){New-Item -ItemType Directory -Path $GuardDir -Force|Out-Null}
    Copy-Item -LiteralPath (Join-Path $Payload 'mosali_peak_guard.py') -Destination (Join-Path $GuardDir 'mosali_peak_guard.py') -Force
    & $HermesPython -m py_compile (Join-Path $GuardDir 'mosali_peak_guard.py'); if($LASTEXITCODE -ne 0){throw 'Peak Guard py_compile FAIL'}
    $hpyw=Join-Path ([IO.Path]::GetDirectoryName($HermesPython)) 'pythonw.exe'; if(-not(Test-Path -LiteralPath $hpyw)){$hpyw=$HermesPython}
    $gp=Start-Process -FilePath $hpyw -ArgumentList ('"{0}"' -f (Join-Path $GuardDir 'mosali_peak_guard.py')) -WindowStyle Hidden -PassThru
    $GuardPid=$gp.Id; Start-Sleep -Seconds 3
    if(-not(Test-Path -LiteralPath (Join-Path $GuardDir 'guard_state.json') -PathType Leaf)){throw 'Peak Guard State fehlt.'}

    Step 9 9 'Finale Verifikation und Ergebnis'
    $final=[ordered]@{status='PASS_PERFORMANCE_STABILITY_FIX_V1_0';time=(Get-Date).ToString('o');backend_hash=(Sha $Backend);wake_hash=(Sha $Wake);hermes_hash=(Sha $HermesCore);stt_ready=(Test-Json 'http://127.0.0.1:17868/health' 'MOSALI_STT_RESIDENT');tts_ready=(Test-Json 'http://127.0.0.1:17869/health' 'MOSALI_TTS_RESIDENT');simon_ready=(Test-Json 'http://127.0.0.1:17861/api/status');hermes_ready=(Test-Json 'http://127.0.0.1:17865/v1/execution/capabilities');wake_count=(WakeCount);guard_pid=$GuardPid;backup=$BackupRoot}
    if(-not($final.stt_ready -and $final.tts_ready -and $final.simon_ready -and $final.hermes_ready -and $final.wake_count -eq 1)){throw 'Finale Verifikation nicht komplett PASS.'}
    JsonFile $final (Join-Path $Evidence '90_FINAL.json')
    Make-Result 'PASS_PERFORMANCE_STABILITY_FIX_V1_0'
    Write-Progress -Id 1 -Activity 'MOSALI Performance Stability Fix V1.0' -Completed
    Write-Host 'PASS_PERFORMANCE_STABILITY_FIX_V1_0' -ForegroundColor Green
    exit 0
}
catch {
    $err=$_.Exception.Message
    try { JsonFile ([ordered]@{status='FAIL';error=$err;position=$_.InvocationInfo.PositionMessage;mutation_started=$MutationStarted}) (Join-Path $Evidence '99_ERROR.json') } catch {}
    if($MutationStarted){ try{Rollback $err}catch{} }
    try{Make-Result 'FAIL_PERFORMANCE_STABILITY_FIX_V1_0' $err}catch{}
    Write-Progress -Id 1 -Activity 'MOSALI Performance Stability Fix V1.0' -Completed
    Write-Host "FAIL: $err" -ForegroundColor Red
    exit 1
}
