<#
.SYNOPSIS
Liest aus, ob dieser Rechner fuer das Remote-Training taugt. Aendert nichts.

.DESCRIPTION
Zeigt Windows-Version, Prozessor, Arbeitsspeicher, freien Speicher, Grafikkarte, WSL-Stand, Kontotyp und
Energieeinstellungen und legt dasselbe in die Zwischenablage - einfach mit Strg+V in die Nachricht an den
Auftraggeber einfuegen. Zusaetzlich als Datei C:\RemoteTraining\RemoteTraining_Inventar.txt (nicht auf den Desktop),
falls die Zwischenablage inzwischen ueberschrieben wurde. Der Text enthaelt keine Seriennummern, E-Mail-Adressen
oder Passwoerter.

Aufruf ohne Download (PowerShell, kein Administrator noetig):
  irm https://raw.githubusercontent.com/studentspub/remote-training/main/inventar.ps1 | iex

.PARAMETER Ausgabe
Ordner fuer RemoteTraining_Inventar.txt (Einrichtung und Pruef-Job, dann ohne Zwischenablage).
Ohne: C:\RemoteTraining und Zwischenablage.
#>
param([string]$Ausgabe = '')

$ErrorActionPreference = 'SilentlyContinue'
$env:WSL_UTF8 = '1'
$zeilen = New-Object System.Collections.Generic.List[string]
function Z([string]$text) { $zeilen.Add($text); Write-Host $text }
function Hex2([string]$alias1, [string]$alias2) {
    # powercfg ist lokalisiert - die letzten zwei Hex-Werte sind immer Netz (AC) und Akku (DC).
    # /qh statt /query: zeigt auch versteckte Einstellungen (Deckel zuklappen ist versteckt)
    $werte = [regex]::Matches((powercfg /qh SCHEME_CURRENT $alias1 $alias2 | Out-String), '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToInt32($_.Value, 16) }
    if ($werte.Count -ge 2) { $werte[$werte.Count - 2] } else { $null }
}

Z "RemoteTraining Inventar $(Get-Date -Format 'dd.MM.yyyy HH:mm')"
Z ''

$os = Get-CimInstance Win32_OperatingSystem
$reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Z "Windows:        $($os.Caption) $($reg.DisplayVersion), Build $($os.BuildNumber).$($reg.UBR)"
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Z "Prozessor:      $($cpu.Name.Trim()) ($($cpu.NumberOfCores) Kerne, $($cpu.NumberOfLogicalProcessors) Threads)"
Z ("Arbeitsspeicher: {0:N0} GB" -f ($os.TotalVisibleMemorySize / 1MB))
$laptop = [bool](Get-CimInstance Win32_Battery)
Z "Laptop:         $(if ($laptop) { 'ja (Akku vorhanden)' } else { 'nein' })"
Z ''

Z 'Laufwerke:'
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    Z ("  {0} {1,6:N0} GB frei von {2,6:N0} GB" -f $_.DeviceID, ($_.FreeSpace / 1GB), ($_.Size / 1GB))
}
Z ''

$smi = (Get-Command nvidia-smi.exe).Source
if (-not $smi -and (Test-Path "$env:SystemRoot\System32\nvidia-smi.exe")) { $smi = "$env:SystemRoot\System32\nvidia-smi.exe" }
if ($smi) {
    $gpu = & $smi --query-gpu=name,memory.total,driver_version,power.draw,power.limit --format=csv,noheader
    foreach ($g in @($gpu)) {
        $t = $g -split ',\s*'
        Z "Grafikkarte:    $($t[0]), $($t[1]) VRAM, Treiber $($t[2])"
        Z "  Stromwert:    aktuell $($t[3]), Limit $($t[4])$(if ($t[3] -match 'N/A') { '  -> kein Messwert, Stromlog nur geschaetzt' })"
    }
    $cuda = [regex]::Match((& $smi | Out-String), 'CUDA (?:UMD |Driver )?Version:\s*([\d.]+)').Groups[1].Value
    Z "  CUDA (Treiber): $cuda"
} else {
    Z 'Grafikkarte:    keine NVIDIA-Karte gefunden (nvidia-smi fehlt) - fuer das Training ungeeignet'
    Get-CimInstance Win32_VideoController | ForEach-Object { Z "  vorhanden: $($_.Name)" }
}
Z ''

# Laeuft schon ein Hypervisor, meldet die Firmware-Abfrage immer "aus" - dann ist Virtualisierung trotzdem an
$hv = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
Z "Virtualisierung: $(if ($hv) { 'an (Hypervisor laeuft)' } elseif ($cpu.VirtualizationFirmwareEnabled) { 'an' } else { 'AUS - im BIOS/UEFI einschalten (Intel VT-x / AMD SVM)' })"
$wslVersion = (wsl.exe --version 2>$null | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $wslVersion) {
    Z 'WSL:            installiert'
    $wslVersion -split "`r?`n" | Select-Object -First 2 | ForEach-Object { Z "  $($_.Trim())" }
    $liste = (wsl.exe -l -v 2>$null | Out-String).Trim()
    if ($liste) { $liste -split "`r?`n" | ForEach-Object { Z "  $($_.Trim())" } }
} else {
    Z 'WSL:            nicht installiert (die Einrichtung installiert es, evtl. mit einem Neustart)'
}
$wslconfig = "$env:USERPROFILE\.wslconfig"
if (Test-Path $wslconfig) {
    Z "  .wslconfig:   $((Get-Content $wslconfig | Where-Object { $_ -match '^\s*(memory|swap|processors)\s*=' }) -join ', ')"
}
Z ''

$konto = Get-LocalUser -Name $env:USERNAME
$art = switch ("$($konto.PrincipalSource)") { 'MicrosoftAccount' { 'Microsoft-Konto' } 'Local' { 'lokales Konto' } default { 'Domaene/Arbeitskonto oder unbekannt' } }
$admin = (whoami /groups /fo csv | ConvertFrom-Csv | Where-Object { $_.SID -eq 'S-1-5-32-544' }) -ne $null
Z "Konto:          $art, $(if ($admin) { 'Administrator' } else { 'kein Administrator - Einrichtung braucht ein Admin-Konto' })"
Z ''

$schema = [regex]::Match((powercfg /getactivescheme | Out-String), '\((.+)\)').Groups[1].Value
Z "Energie (am Netz), Schema '$schema':"
$standby = Hex2 SUB_SLEEP STANDBYIDLE
$ruhe = Hex2 SUB_SLEEP HIBERNATEIDLE
$deckel = Hex2 SUB_BUTTONS LIDACTION
Z "  Energiesparmodus nach: $(if ($standby -eq 0) { 'nie' } elseif ($standby) { "$([int]($standby / 60)) min" } else { '?' })"
Z "  Ruhezustand nach:      $(if ($ruhe -eq 0) { 'nie' } elseif ($ruhe) { "$([int]($ruhe / 60)) min" } else { '?' })"
if ($laptop) {
    $namen = @('nichts tun', 'Energie sparen', 'Ruhezustand', 'Herunterfahren', 'Bildschirm ausschalten')
    Z "  Deckel zuklappen:      $(if ($null -eq $deckel) { '?' } elseif ($deckel -lt $namen.Count) { $namen[$deckel] } else { "Wert $deckel" })"
}

Write-Host ''
$ordner = if ($Ausgabe) { $Ausgabe } else { 'C:\RemoteTraining' }
$datei = Join-Path $ordner 'RemoteTraining_Inventar.txt'
try {
    New-Item -ItemType Directory -Force $ordner | Out-Null
    $zeilen | Set-Content -Path $datei -Encoding UTF8
    Write-Host "Gespeichert: $datei" -ForegroundColor Green
} catch {
    Write-Host "Datei ging nicht ($datei)" -ForegroundColor Yellow
}
if (-not $Ausgabe) {
    try {
        $zeilen -join "`r`n" | Set-Clipboard
        Write-Host 'Liegt in der Zwischenablage - einfach mit Strg+V in die Nachricht an den Auftraggeber einfuegen.' -ForegroundColor Green
    } catch {
        Write-Host 'Zwischenablage ging nicht - bitte die Datei oben schicken.' -ForegroundColor Yellow
    }
}
