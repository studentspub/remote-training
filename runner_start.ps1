<#
.SYNOPSIS
Startet den GitHub-Runner, wenn der Remote-Modus eingeschaltet ist.

.DESCRIPTION
Wird von der Aufgabe "RemoteTraining Runner" bei der Anmeldung und von "remote_modus.ps1 ein" gestartet.
Laeuft unsichtbar im eigenen Benutzerkonto (kein Dienst, kein Windows-Passwort noetig). Ist der Remote-Modus
aus oder laeuft der Runner schon, endet das Skript sofort. Ausgabe des Runners: C:\RemoteTraining\logs\runner.log

.PARAMETER DryRun
Nur anzeigen, ob der Runner gestartet wuerde.
#>
param([switch]$DryRun)
$Basis = 'C:\RemoteTraining'
$zustand = if (Test-Path "$Basis\remote_modus.json") { Get-Content "$Basis\remote_modus.json" -Raw | ConvertFrom-Json }
if (-not $zustand.aktiv) { 'Remote-Modus ist aus - Runner bleibt aus.'; exit 0 }
if (Get-Process Runner.Listener -ErrorAction SilentlyContinue) { 'Runner laeuft schon.'; exit 0 }
if (-not (Test-Path "$Basis\runner\.runner")) { 'Runner ist nicht registriert (einrichten.ps1).'; exit 1 }
if ($DryRun) { "[dry-run] wuerde $Basis\runner\run.cmd starten"; exit 0 }
Set-Location "$Basis\runner"
& cmd.exe /c run.cmd *>> "$Basis\logs\runner.log"
