<#
.SYNOPSIS
Farbiger Punkt im Infobereich der Taskleiste: zeigt, ob der Rechner gerade fuer das Remote-Training arbeitet.

.DESCRIPTION
  gruen  Remote-Modus EIN, wartet auf Auftraege - der Rechner ist frei
  rot    arbeitet gerade (Training oder Pruefung laeuft)
  gelb   Remote-Modus EIN, Runner startet noch
  grau   Remote-Modus AUS - der Rechner gehoert dir
Rechtsklick auf den Punkt: Remote-Modus EIN / AUS, Status anzeigen, Anzeige beenden. Doppelklick: kurze Meldung.
Beim Start (wenn der Remote-Modus an ist) und bei jedem Wechsel erscheint eine kurze Meldung.
Startet bei der Anmeldung (Aufgabe "RemoteTraining Tray", legt remote_modus.ps1 an). Fragt alle 5 s den Zustand ab
(remote_modus.json, Runner-Prozesse) und aendert selbst nichts - EIN/AUS ruft remote_modus.ps1 auf.

.PARAMETER DryRun
Nur den aktuellen Zustand ausgeben, keine Anzeige.
#>
param([switch]$DryRun)
$Basis = 'C:\RemoteTraining'
$Hier = $PSScriptRoot

function Zustand {
    $z = if (Test-Path "$Basis\remote_modus.json") { Get-Content "$Basis\remote_modus.json" -Raw | ConvertFrom-Json }
    if (Get-Process Runner.Worker -ErrorAction SilentlyContinue) { 'arbeitet' }
    elseif ($z.aktiv -and (Get-Process Runner.Listener -ErrorAction SilentlyContinue)) { 'frei' }
    elseif ($z.aktiv) { 'startet' }
    else { 'aus' }
}
# Text am Punkt (Windows erlaubt hoechstens 63 Zeichen)
$Texte = @{
    arbeitet = 'Remote-Training: arbeitet gerade'
    frei     = 'Remote-Training: EIN - frei, wartet auf Auftraege'
    startet  = 'Remote-Training: EIN - Runner startet'
    aus      = 'Remote-Training: AUS - der Rechner gehoert dir'
}
$Meldungen = @{
    arbeitet = 'Ein Training laeuft. Zum Spielen: Rechtsklick auf den Punkt -> Remote-Modus AUS (Training stoppt sofort).'
    frei     = 'Remote-Modus ist EIN - dieser Rechner nimmt Trainingsauftraege an. Bitte sperren, nicht abmelden.'
    startet  = 'Remote-Modus ist EIN - der Runner startet.'
    aus      = 'Remote-Modus ist AUS - der Rechner gehoert wieder dir.'
}

if ($DryRun) { $s = Zustand; "Zustand: $s - $($Texte[$s])"; exit 0 }

# nur eine Anzeige pro Anmeldung
$neu = $false
$sperre = New-Object System.Threading.Mutex($true, 'Local\RemoteTrainingTray', [ref]$neu)
if (-not $neu) { exit 0 }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
function Punkt([int]$r, [int]$g, [int]$b) {
    $bild = New-Object System.Drawing.Bitmap 32, 32
    $zeichnen = [System.Drawing.Graphics]::FromImage($bild)
    $zeichnen.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $zeichnen.Clear([System.Drawing.Color]::Transparent)
    $zeichnen.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($r, $g, $b))), 3, 3, 26, 26)
    $zeichnen.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(110, 0, 0, 0)), 2), 3, 3, 26, 26)
    $zeichnen.Dispose()
    [System.Drawing.Icon]::FromHandle($bild.GetHicon())
}
$Punkte = @{ arbeitet = (Punkt 220 38 38); frei = (Punkt 22 163 74); startet = (Punkt 234 179 8); aus = (Punkt 150 150 150) }

function Modus([string]$aktion) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Hier\remote_modus.ps1`" $aktion"
}

$anzeige = New-Object System.Windows.Forms.NotifyIcon
$menue = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menue.Items.Add('Remote-Modus EIN', $null, { Modus 'ein' })
[void]$menue.Items.Add('Remote-Modus AUS (Training stoppt sofort)', $null, { Modus 'aus' })
[void]$menue.Items.Add('Status anzeigen', $null, {
    Start-Process powershell.exe -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$Hier\remote_modus.ps1`" status"
})
[void]$menue.Items.Add('-')
[void]$menue.Items.Add('Anzeige beenden', $null, { $anzeige.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$anzeige.ContextMenuStrip = $menue
$anzeige.add_DoubleClick({ $anzeige.ShowBalloonTip(4000, 'Remote-Training', $Meldungen[$script:stand], 'Info') })

$script:stand = $null
$aktualisieren = {
    $s = Zustand
    if ($s -ne $script:stand) {
        $anzeige.Icon = $Punkte[$s]
        $anzeige.Text = $Texte[$s]
        # Meldung bei jedem Wechsel; beim Start nur, wenn der Remote-Modus an ist (Hinweis nach der Anmeldung)
        if ($null -ne $script:stand -or $s -ne 'aus') { $anzeige.ShowBalloonTip(6000, 'Remote-Training', $Meldungen[$s], 'Info') }
        $script:stand = $s
    }
}
& $aktualisieren
$anzeige.Visible = $true
$uhr = New-Object System.Windows.Forms.Timer
$uhr.Interval = 5000
$uhr.add_Tick($aktualisieren)
$uhr.Start()
[System.Windows.Forms.Application]::Run()
$anzeige.Dispose()
