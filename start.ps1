<#
.SYNOPSIS
Laedt die Einrichtung herunter und startet sie - die eine Zeile, die der Auftraggeber schickt.

.DESCRIPTION
In PowerShell einfuegen (Start -> "PowerShell" tippen -> Enter), dann die Windows-Abfrage mit "Ja" bestaetigen:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/studentspub/remote-training/main/start.ps1))) -Token <TOKEN> -Name <NAME>
Laedt dieses Repo als ZIP nach C:\RemoteTraining\setup und startet einrichten.ps1 als Administrator.
Alles Weitere laeuft ohne Zutun (siehe einrichten.ps1).

.PARAMETER Token
Runner-Registrierungstoken vom Auftraggeber (1 h gueltig).

.PARAMETER Name
Name dieses Rechners vom Auftraggeber (z.B. laptop).

.PARAMETER DryRun
Nur in einen Temp-Ordner laden und einrichten.ps1 im Testmodus zeigen lassen; richtet nichts ein.
#>
param([string]$Token, [string]$Name, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$tmp = Join-Path $env:TEMP "remote-training-$(Get-Date -Format yyyyMMddHHmmss)"
New-Item -ItemType Directory $tmp | Out-Null
Write-Host 'Lade die Einrichtung ...'
Invoke-WebRequest 'https://github.com/studentspub/remote-training/archive/refs/heads/main.zip' -OutFile "$tmp\setup.zip" -UseBasicParsing
Expand-Archive "$tmp\setup.zip" $tmp
$quelle = Join-Path $tmp 'remote-training-main'

$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
if ($DryRun) {
    $a += "`"$quelle\einrichten.ps1`""
    if ($Name) { $a += @('-Name', $Name) }
    & powershell.exe @a -DryRun
    return
}
$ziel = 'C:\RemoteTraining\setup'
New-Item -ItemType Directory -Force $ziel | Out-Null
Copy-Item "$quelle\*" $ziel -Recurse -Force
$a += "`"$ziel\einrichten.ps1`""
if ($Token) { $a += @('-Token', $Token) }
if ($Name) { $a += @('-Name', $Name) }
Start-Process powershell.exe -Verb RunAs -ArgumentList $a
Write-Host 'Die Einrichtung laeuft im neuen Fenster weiter (Windows-Abfrage mit "Ja" bestaetigen).' -ForegroundColor Green
