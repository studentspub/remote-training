<#
.SYNOPSIS
Remote-Modus ein- oder ausschalten oder anzeigen.

.DESCRIPTION
ein     Energiesparmodus und Ruhezustand am Netz auf "nie", Deckel zuklappen auf "nichts tun" (alte Werte werden
        gemerkt), dann den Runner starten. Danach nimmt der Rechner Trainings-Auftraege an. Bildschirm sperren ist
        ok - aber nicht abmelden, sonst laeuft nichts.
aus     Sofort: Training beenden (nur die Distribution RemoteTraining, anderes WSL/Docker bleibt), Runner beenden,
        Energieeinstellungen zuruecksetzen. Ein abgebrochenes Training macht spaeter beim letzten Stand weiter.
status  Zeigt Remote-Modus, Runner, laufendes Training, Energieeinstellungen, Basismodell.
Kein Administrator noetig. Die Desktop-Verknuepfungen "Remote-Modus EIN/AUS/Status" rufen dieses Skript auf.

.PARAMETER Aktion
ein | aus | status (Standard status)

.PARAMETER Warten
Fenster am Ende ein paar Sekunden offen lassen (fuer die Desktop-Verknuepfungen).

.PARAMETER DryRun
Nur anzeigen, was passieren wuerde.
#>
param([ValidateSet('ein', 'aus', 'status')][string]$Aktion = 'status', [switch]$Warten, [switch]$DryRun)

$Basis = 'C:\RemoteTraining'
$Distro = 'RemoteTraining'
$AufgabeRunner = 'RemoteTraining Runner'
$Datei = "$Basis\remote_modus.json"
$env:WSL_UTF8 = '1'

function Lies {
    if (Test-Path $Datei) { Get-Content $Datei -Raw | ConvertFrom-Json }
    else { [pscustomobject]@{ aktiv = $false; seit = $null; energie_alt = $null } }
}
function Schreib($z) {
    if ($DryRun) { Write-Host "[dry-run] wuerde Zustand speichern: aktiv=$($z.aktiv)"; return }
    $z | ConvertTo-Json | Set-Content $Datei -Encoding UTF8
}
function Tu([string]$was, [scriptblock]$aktion) {
    if ($DryRun) { Write-Host "[dry-run] wuerde: $was" -ForegroundColor Yellow } else { & $aktion }
}
function AcWert([string]$a1, [string]$a2) {
    # powercfg ist lokalisiert - die letzten zwei Hex-Werte sind immer Netz (AC) und Akku (DC)
    $w = [regex]::Matches((powercfg /query SCHEME_CURRENT $a1 $a2 | Out-String), '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToInt32($_.Value, 16) }
    if ($w.Count -ge 2) { $w[$w.Count - 2] } else { $null }
}
function SetzeEnergie([int]$standby, [int]$ruhe, [int]$deckel) {
    powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE $standby
    powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE $ruhe
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $deckel
    powercfg /setactive SCHEME_CURRENT
}
function RunnerProzesse {
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*RemoteTraining\runner*' -or $_.CommandLine -like '*runner_start.ps1*' }
}
function Minuten($s) { if ($null -eq $s) { '?' } elseif ($s -eq 0) { 'nie' } else { "$([int]($s / 60)) min" } }

$z = Lies
switch ($Aktion) {
    'ein' {
        if (-not (Test-Path "$Basis\runner\.runner")) { Write-Host 'Runner ist nicht eingerichtet - zuerst die Einrichtung ausfuehren.' -ForegroundColor Red; break }
        if (-not $z.aktiv) {
            $z.energie_alt = [pscustomobject]@{ standby = (AcWert SUB_SLEEP STANDBYIDLE); ruhe = (AcWert SUB_SLEEP HIBERNATEIDLE); deckel = (AcWert SUB_BUTTONS LIDACTION) }
        }
        Tu 'Energiesparmodus/Ruhezustand am Netz auf "nie", Deckel zuklappen auf "nichts tun"' { SetzeEnergie 0 0 0 }
        $z.aktiv = $true
        $z.seit = (Get-Date).ToString('s')
        Schreib $z
        if (Get-Process Runner.Listener -ErrorAction SilentlyContinue) { Write-Host 'Runner laeuft schon.' }
        else { Tu "Aufgabe '$AufgabeRunner' starten (Runner)" { Start-ScheduledTask -TaskName $AufgabeRunner } }
        Write-Host 'Remote-Modus ist EIN. Bildschirm sperren ist ok, bitte nicht abmelden.' -ForegroundColor Green
    }
    'aus' {
        Tu "Training sofort beenden (wsl --terminate $Distro)" { wsl.exe --terminate $Distro 2>$null | Out-Null }
        Tu 'Runner beenden' { RunnerProzesse | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
        if ($z.energie_alt) {
            $e = $z.energie_alt
            Tu "Energieeinstellungen zuruecksetzen (Standby $(Minuten $e.standby), Ruhezustand $(Minuten $e.ruhe))" { SetzeEnergie $e.standby $e.ruhe $e.deckel }
        }
        $z.aktiv = $false
        $z.seit = (Get-Date).ToString('s')
        $z.energie_alt = $null
        Schreib $z
        Write-Host 'Remote-Modus ist AUS. Der Rechner gehoert wieder dir.' -ForegroundColor Green
    }
    'status' {
        $runnerDa = Test-Path "$Basis\runner\.runner"
        $laeuft = [bool](Get-Process Runner.Listener -ErrorAction SilentlyContinue)
        $training = @(wsl.exe -l --running -q 2>$null | ForEach-Object { $_.Trim([char]0, ' ') }) -contains $Distro
        Write-Host "Remote-Modus:   $(if ($z.aktiv) { "EIN seit $($z.seit)" } else { 'AUS' })"
        Write-Host "Runner:         $(if (-not $runnerDa) { 'nicht eingerichtet' } elseif ($laeuft) { 'laeuft (nimmt Auftraege an)' } else { 'aus' })"
        Write-Host "Training:       $(if ($training) { 'laeuft gerade' } else { 'keins' })"
        Write-Host "Energie (Netz): Energiesparmodus $(Minuten (AcWert SUB_SLEEP STANDBYIDLE)), Ruhezustand $(Minuten (AcWert SUB_SLEEP HIBERNATEIDLE))"
        $modelle = @(Get-ChildItem "$Basis\modelle" -Filter *.safetensors -ErrorAction SilentlyContinue | ForEach-Object Name)
        Write-Host "Basismodelle:   $(if ($modelle) { $modelle -join ', ' } else { 'keins in C:\RemoteTraining\modelle' })"
    }
}
if ($Warten) { Start-Sleep -Seconds 6 }
