<#
.SYNOPSIS
Richtet diesen Rechner ohne weiteres Zutun fuer das Remote-Training ein.

.DESCRIPTION
Wird normalerweise von start.ps1 gestartet (Startzeile vom Auftraggeber). Schritte:
  1. Pruefungen (Windows, NVIDIA-Karte, Speicherplatz, Konto), Inventar ins Log
  2. GitHub-Runner laden, registrieren und als Aufgabe bei der Anmeldung eintragen - zuerst, damit das Token
     (1 h gueltig) auch dann reicht, wenn spaeter ein Neustart noetig ist
  3. WSL installieren; muss Windows dafuer neu starten, startet es nach 2 Minuten automatisch neu und die
     Einrichtung geht nach der Anmeldung von selbst weiter
  4. WSL-Speicher (.wslconfig, vorhandene Werte bleiben), eigene Distribution "RemoteTraining" (Ubuntu 22.04)
  5. Kohya sd-scripts mit allen Paketen in der Distribution (wsl_einrichten.sh), GPU-Test
  6. Desktop-Verknuepfungen "Remote-Modus EIN/AUS/Status", Remote-Modus einschalten
Laeuft mehrfach gefahrlos (fertige Schritte werden uebersprungen). Log: C:\RemoteTraining\logs\einrichtung_*.log,
am Ende auch als RemoteTraining_Einrichtung.log auf dem Desktop.

.PARAMETER Token
Runner-Registrierungstoken vom Auftraggeber (1 h gueltig, nur einmal nutzbar).

.PARAMETER Name
Name dieses Rechners vom Auftraggeber (z.B. laptop), zugleich Runner-Label.

.PARAMETER DryRun
Nur anzeigen, was passieren wuerde. Aendert nichts und braucht keine Administratorrechte.

.PARAMETER Fortsetzung
Intern: Lauf nach dem Neustart.
#>
param([string]$Token, [string]$Name, [switch]$DryRun, [switch]$Fortsetzung)

$Basis = 'C:\RemoteTraining'
$Distro = 'RemoteTraining'
$RepoJobs = 'https://github.com/studentspub/remote-training-jobs'
$RunnerVersion = '2.338.0'
$RunnerSha256 = 'f48e0750a21812bca5f82de5f7f5aeae71abee647fab5a582f1742d07eba455f'
$UbuntuOrdner = 'https://cloud-images.ubuntu.com/wsl/jammy/current'
$UbuntuDatei = 'ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz'
$Basismodell = 'prefectIllustriousXL_v60.safetensors'
$MinFreiGB = 40
$AufgabeRunner = 'RemoteTraining Runner'
$AufgabeWeiter = 'RemoteTraining Einrichtung fortsetzen'

# --- Als Administrator neu starten (eine Windows-Abfrage) ------------------------------------------------------
$istAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $istAdmin -and -not $DryRun) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Token) { $a += @('-Token', $Token) }
    if ($Name) { $a += @('-Name', $Name) }
    if ($Fortsetzung) { $a += '-Fortsetzung' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    return
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$env:WSL_UTF8 = '1'
$Hier = $PSScriptRoot
$Start = Get-Date
$LogDatei = "$Basis\logs\einrichtung_$(Get-Date -Format yyyyMMdd_HHmmss).log"
$Ergebnis = [ordered]@{}
$script:Neustart = $false
$Benutzer = "$env:USERDOMAIN\$env:USERNAME"

if (-not $DryRun) { New-Item -ItemType Directory -Force "$Basis\logs" | Out-Null }

function Log([string]$t, [string]$farbe = 'Gray') {
    if ($Token) { $t = $t.Replace($Token, '***') }
    $z = "$(Get-Date -Format HH:mm:ss) $t"
    Write-Host $z -ForegroundColor $farbe
    if (-not $DryRun) { Add-Content -Path $LogDatei -Value $z -Encoding UTF8 }
}
function Extern([string]$exe, [string[]]$argumente) {
    Log "  > $([IO.Path]::GetFileName($exe)) $($argumente -join ' ')" DarkGray
    $ErrorActionPreference = 'Continue'
    & $exe @argumente 2>&1 | ForEach-Object { $z = "$_".Trim([char]0, ' ', "`r", "`n"); if ($z) { Log "    $z" DarkGray } }
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($exe)) endete mit Code $LASTEXITCODE" }
}
function Schritt([string]$titel, [scriptblock]$aktion) {
    Log "== $titel" Cyan
    $t = Get-Date
    try {
        & $aktion
        if (-not $Ergebnis.Contains($titel)) { $Ergebnis[$titel] = "ok ($([int]((Get-Date) - $t).TotalSeconds) s)" }
        Log "   ok" Green
    } catch {
        $Ergebnis[$titel] = "FEHLER: $($_.Exception.Message)"
        Log "   FEHLER: $($_.Exception.Message)" Red
        throw
    }
}
function Tu([string]$was, [scriptblock]$aktion) {
    if ($DryRun) { Log "   [dry-run] wuerde: $was" Yellow } else { Log "   $was"; & $aktion }
}
function Laden([string]$url, [string]$ziel) {
    Log "   laden: $url"
    Invoke-WebRequest -Uri $url -OutFile $ziel -UseBasicParsing
}
function WslPfad([string]$p) { '/mnt/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/') }
function Distros { @(wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim([char]0, ' ') } | Where-Object { $_ }) }
function Aufgabe([string]$name, [string]$skript, [string]$argumente, [string]$stufe, [switch]$Versteckt) {
    $fenster = if ($Versteckt) { '-WindowStyle Hidden ' } else { '' }
    $aktion = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile $fenster-ExecutionPolicy Bypass -File `"$skript`" $argumente"
    $ausloeser = New-ScheduledTaskTrigger -AtLogOn -User $Benutzer
    $konto = New-ScheduledTaskPrincipal -UserId $Benutzer -LogonType Interactive -RunLevel $stufe
    $einst = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $name -Action $aktion -Trigger $ausloeser -Principal $konto -Settings $einst -Force | Out-Null
}

Log "RemoteTraining Einrichtung$(if ($Fortsetzung) { ' (Fortsetzung nach Neustart)' })$(if ($DryRun) { ' - TESTMODUS, es wird nichts geaendert' })" White
Log "Rechner: $env:COMPUTERNAME, Konto: $Benutzer, Name: $(if ($Name) { $Name } else { '-' }), Skripte: $Hier"

$ok = $false
try {
    Schritt 'Pruefungen' {
        $os = Get-CimInstance Win32_OperatingSystem
        if ([int]$os.BuildNumber -lt 19044) { throw "Windows-Build $($os.BuildNumber) ist zu alt (mindestens Windows 10 21H2)" }
        if (-not (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue)) { throw 'Keine NVIDIA-Grafikkarte oder kein Treiber (nvidia-smi fehlt)' }
        $frei = (Get-PSDrive C).Free / 1GB
        Log ("   C: {0:N0} GB frei (noetig ~{1} GB)" -f $frei, $MinFreiGB)
        if ($frei -lt $MinFreiGB) { throw "Zu wenig Platz auf C: ($([int]$frei) GB frei, noetig $MinFreiGB GB)" }
        $sitzung = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Invoke-CimMethod -MethodName GetOwner | ForEach-Object User)
        if ($sitzung -and $sitzung -notcontains $env:USERNAME) {
            throw "Die Einrichtung laeuft als '$env:USERNAME', angemeldet ist '$($sitzung -join ', ')'. Bitte im eigenen Konto starten (das Konto braucht Administratorrechte)."
        }
        if (-not $DryRun) {
            New-Item -ItemType Directory -Force "$Basis\modelle", "$Basis\ausgabe", "$Basis\runner", "$Basis\wsl", "$Basis\downloads" | Out-Null
            # Runner und Remote-Modus laufen ohne Adminrechte - das Konto braucht Vollzugriff auf C:\RemoteTraining
            $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
            icacls.exe $Basis /grant "*${sid}:(OI)(CI)F" /T /Q | Out-Null
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Hier\inventar.ps1" -Ausgabe "$Basis\logs" | ForEach-Object { Log "   $_" DarkGray }
        }
    }

    Schritt 'GitHub-Runner' {
        $runner = "$Basis\runner"
        if (Test-Path "$runner\.runner") {
            $vorhanden = (Get-Content "$runner\.runner" -Raw | ConvertFrom-Json).agentName
            Log "   Runner '$vorhanden' ist schon registriert"
        } elseif (-not $Token -or -not $Name) {
            throw 'Token oder Name fehlt - bitte die vollstaendige Startzeile vom Auftraggeber verwenden'
        } else {
            if (-not (Test-Path "$runner\config.cmd")) {
                $zip = "$Basis\downloads\actions-runner-win-x64-$RunnerVersion.zip"
                Tu "Runner $RunnerVersion laden und pruefen" {
                    Laden "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip" $zip
                    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $RunnerSha256) { throw 'Pruefsumme des Runners stimmt nicht' }
                    Expand-Archive $zip $runner -Force
                }
            }
            Tu "Runner '$Name' am privaten Repo registrieren" {
                Push-Location $runner
                try { Extern "$runner\config.cmd" @('--unattended', '--url', $RepoJobs, '--token', $Token, '--name', $Name, '--labels', $Name, '--work', '_work', '--replace') }
                finally { Pop-Location }
            }
        }
        Tu "Aufgabe '$AufgabeRunner' (startet den Runner bei der Anmeldung, wenn der Remote-Modus an ist)" {
            Aufgabe $AufgabeRunner "$Hier\runner_start.ps1" '' 'Limited' -Versteckt
        }
    }

    Schritt 'WSL' {
        $ErrorActionPreference = 'Continue'
        wsl.exe --status *> $null
        $wslDa = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = 'Stop'
        $merkmale = 'VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux'
        $stand = @{}
        foreach ($m in $merkmale) { $stand[$m] = try { "$((Get-WindowsOptionalFeature -Online -FeatureName $m).State)" } catch { 'unbekannt' } }
        Log "   WSL vorhanden: $wslDa, VirtualMachinePlatform: $($stand['VirtualMachinePlatform'])"
        if (-not $wslDa -or $stand['VirtualMachinePlatform'] -eq 'Disabled') {
            Tu 'WSL installieren (wsl --install --no-distribution)' { Extern wsl.exe @('--install', '--no-distribution') }
            if (-not $DryRun) { foreach ($m in $merkmale) { $stand[$m] = "$((Get-WindowsOptionalFeature -Online -FeatureName $m).State)" } }
        }
        if ($stand.Values -contains 'EnablePending') {
            $script:Neustart = $true
            $weiter = '-Fortsetzung' + $(if ($Name) { " -Name $Name" } else { '' })
            Tu "Aufgabe '$AufgabeWeiter' (macht nach dem Neustart weiter)" { Aufgabe $AufgabeWeiter "$Hier\einrichten.ps1" $weiter 'Highest' }
            Tu 'Neustart in 2 Minuten (abbrechen mit: shutdown /a)' {
                shutdown.exe /r /t 120 /c 'RemoteTraining: Neustart fuer WSL. Nach der Anmeldung geht die Einrichtung von selbst weiter.'
            }
            $Ergebnis['WSL'] = 'Neustart noetig - geht nach der Anmeldung weiter'
            return
        }
        Tu 'WSL aktualisieren (wsl --update)' {
            try { Extern wsl.exe @('--update') } catch { Log "   Hinweis: wsl --update ging nicht ($($_.Exception.Message)) - weiter mit vorhandener Version" Yellow }
        }
    }

    if (-not $script:Neustart) {
        Schritt 'WSL-Speicher (.wslconfig)' {
            $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
            $mem = [math]::Max(8, $ramGB - 4)
            $pfad = "$env:USERPROFILE\.wslconfig"
            $inhalt = @(if (Test-Path $pfad) { Get-Content $pfad })
            if ($inhalt -match '^\s*memory\s*=') {
                Log "   .wslconfig hat schon einen Speicherwert ($(($inhalt -match '^\s*memory\s*=') -join ', ')) - bleibt unveraendert"
            } else {
                $neu = @("memory=${mem}GB")
                if (-not ($inhalt -match '^\s*swap\s*=')) { $neu += 'swap=8GB' }
                Tu ".wslconfig ergaenzen: $($neu -join ', ') (bei $ramGB GB RAM)" {
                    if (Test-Path $pfad) { Copy-Item $pfad "$pfad.vor_remotetraining" -Force }
                    $liste = New-Object System.Collections.Generic.List[string]
                    $inhalt | ForEach-Object { $liste.Add($_) }
                    $i = -1
                    for ($k = 0; $k -lt $liste.Count; $k++) { if ($liste[$k].Trim() -ieq '[wsl2]') { $i = $k } }
                    if ($i -ge 0) { $liste.InsertRange($i + 1, [string[]]$neu) } else { $liste.Add('[wsl2]'); $liste.AddRange([string[]]$neu) }
                    Set-Content $pfad $liste -Encoding ASCII
                    Log '   WSL neu starten, damit der Wert gilt (wsl --shutdown)'
                    wsl.exe --shutdown 2>$null | Out-Null
                }
            }
        }

        Schritt "Distribution $Distro" {
            if ((Distros) -contains $Distro) {
                Log "   Distribution $Distro gibt es schon"
            } else {
                $tar = "$Basis\downloads\$UbuntuDatei"
                Tu 'Ubuntu 22.04 laden und Pruefsumme kontrollieren' {
                    Laden "$UbuntuOrdner/$UbuntuDatei" $tar
                    $summen = (Invoke-WebRequest "$UbuntuOrdner/SHA256SUMS" -UseBasicParsing).Content
                    if ($summen -is [byte[]]) { $summen = [Text.Encoding]::ASCII.GetString($summen) }
                    $soll = [regex]::Match($summen, "([0-9a-f]{64}) \*?$([regex]::Escape($UbuntuDatei))").Groups[1].Value
                    $ist = (Get-FileHash $tar -Algorithm SHA256).Hash.ToLower()
                    if (-not $soll -or $soll -ne $ist) { throw 'Pruefsumme von Ubuntu stimmt nicht' }
                }
                Tu "Distribution $Distro anlegen (C:\RemoteTraining\wsl)" { Extern wsl.exe @('--import', $Distro, "$Basis\wsl", $tar, '--version', '2') }
            }
        }

        Schritt 'Kohya und GPU-Test' {
            Tu 'Kohya sd-scripts und Pakete in der Distribution einrichten (mehrere GB, dauert)' {
                Extern wsl.exe @('-d', $Distro, '-u', 'root', '-e', 'bash', "$(WslPfad $Hier)/wsl_einrichten.sh")
                wsl.exe --terminate $Distro 2>$null | Out-Null
            }
        }

        Schritt 'Basismodell' {
            # Das erste Training laedt es selbst (OneDrive, SHA256 geprueft). Eine Kopie in C:\RemoteTraining\modelle
            # (z.B. per USB) wird stattdessen genommen, wenn sie da ist.
            if (Test-Path "$Basis\modelle\$Basismodell") { Log "   $Basismodell liegt in C:\RemoteTraining\modelle" }
            else {
                Log "   $Basismodell laedt das erste Training automatisch (einmalig ca. 6,5 GB)"
                $Ergebnis['Basismodell'] = 'kommt mit dem ersten Training'
            }
        }

        Schritt 'Desktop-Verknuepfungen' {
            $desktop = [Environment]::GetFolderPath('Desktop')
            Tu "Remote-Modus EIN / AUS / Status auf dem Desktop ($desktop)" {
                $shell = New-Object -ComObject WScript.Shell
                foreach ($v in @(@('Remote-Modus EIN', 'ein'), @('Remote-Modus AUS', 'aus'), @('Remote-Modus Status', 'status'))) {
                    $l = $shell.CreateShortcut("$desktop\$($v[0]).lnk")
                    $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                    $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Hier\remote_modus.ps1`" $($v[1]) -Warten"
                    $l.WorkingDirectory = $Hier
                    $l.Save()
                }
            }
        }
    }
    $ok = $true
} catch {
    $ok = $false
} finally {
    if (-not $script:Neustart) {
        # Auch nach einem Fehler: laeuft der Runner, holt sich der Auftraggeber die Logs selbst (Workflow "Pruefen")
        if (Test-Path "$Basis\runner\.runner") {
            Tu 'Remote-Modus einschalten' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Hier\remote_modus.ps1" ein | ForEach-Object { Log "   $_" } }
        }
        if ($Fortsetzung) { Tu "Aufgabe '$AufgabeWeiter' entfernen" { Unregister-ScheduledTask -TaskName $AufgabeWeiter -Confirm:$false -ErrorAction SilentlyContinue } }
    }
    $dauer = [int]((Get-Date) - $Start).TotalMinutes
    Log ''
    Log "Ergebnis nach $dauer min:" White
    foreach ($e in $Ergebnis.GetEnumerator()) { Log ("  {0,-28} {1}" -f $e.Key, $e.Value) $(if ("$($e.Value)" -like 'FEHLER*') { 'Red' } else { 'White' }) }
    if (-not $DryRun) { Copy-Item $LogDatei "$([Environment]::GetFolderPath('Desktop'))\RemoteTraining_Einrichtung.log" -Force -ErrorAction SilentlyContinue }
    if ($DryRun) {
        Log 'Testmodus beendet - es wurde nichts geaendert.' Yellow
    } elseif ($script:Neustart) {
        Log 'Windows startet in 2 Minuten neu. Danach anmelden - die Einrichtung macht von selbst weiter.' Yellow
    } elseif ($ok) {
        Log 'Fertig. Der Remote-Modus ist EIN - ausschalten jederzeit mit "Remote-Modus AUS" auf dem Desktop.' Green
    } else {
        Log 'Die Einrichtung ist nicht durchgelaufen. Bitte RemoteTraining_Einrichtung.log vom Desktop an den Auftraggeber schicken.' Red
    }
    if (-not $DryRun -and [Environment]::UserInteractive) { Read-Host 'Enter zum Schliessen' | Out-Null }
}
