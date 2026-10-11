# Remote-Training – Rechenzeit teilen

Mit diesen Skripten kann ein Windows-PC mit NVIDIA-Grafikkarte in seiner freien Zeit LoRA-Trainings übernehmen.
Gesteuert wird alles vom Auftraggeber über GitHub. Du brauchst kein GitHub-Konto, kein VPN und keine Portfreigabe.
Dein Rechner baut nur eine ausgehende Verbindung zu GitHub auf.

## Für dich als Rechner-Besitzer

### Schritt 1 – Taugt mein Rechner? (optional, 1 Minute)
PowerShell öffnen (Start → „PowerShell“ tippen → Enter), diese Zeile einfügen, Enter:

```powershell
irm https://raw.githubusercontent.com/studentspub/remote-training/main/inventar.ps1 | iex
```

Das liest nur aus und ändert nichts. Auf dem Desktop liegt danach `RemoteTraining_Inventar.txt`. Schick sie dem Auftraggeber.
Die Datei enthält keine Seriennummern, E-Mail-Adressen oder Passwörter.

### Schritt 2 – Einrichten (ohne Eingriff, ca. 15–30 Minuten)
Der Auftraggeber schickt dir **eine** Zeile. Sie enthält einen Schlüssel, der 1 Stunde gilt. Sie sieht so aus:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/studentspub/remote-training/main/start.ps1))) -Token XXXX -Name dein-pc
```

Füge sie in PowerShell ein und bestätige die Windows-Abfrage mit **Ja**. Mehr musst du nicht tun:
- **Installation:** Die Einrichtung installiert WSL (Linux unter Windows) und eine eigene Linux-Umgebung `RemoteTraining`. Dazu kommen die Trainingssoftware und ein Hintergrunddienst für die Aufträge.
- **Neustart:** Braucht Windows einen Neustart, startet der Rechner nach 2 Minuten von selbst neu. Abbrechen kannst du mit `shutdown /a`. Nach der Anmeldung läuft die Einrichtung von selbst weiter.
- **Protokoll:** Am Ende liegt `RemoteTraining_Einrichtung.log` auf dem Desktop. Klappt etwas nicht, holt sich der Auftraggeber das Protokoll selbst. Notfalls schickst du ihm die Datei.
- **Platzbedarf:** Alles liegt in `C:\RemoteTraining`, insgesamt ca. 25–30 GB.

Das Basismodell (eine große Datei, ca. 7 GB) bekommst du per USB-Stick oder Link. Kopiere es nach `C:\RemoteTraining\modelle`.

### Schritt 3 – Bedienung
Auf dem Desktop liegen drei Verknüpfungen:

| Verknüpfung | Was passiert |
|---|---|
| **Remote-Modus EIN** | Der Rechner nimmt Aufträge an. Energiesparmodus und Ruhezustand werden am Netz auf „nie“ gestellt. Die alten Werte werden gemerkt. |
| **Remote-Modus AUS** | Ein laufendes Training wird **sofort** beendet und der Rechner gehört wieder dir. Die Energieeinstellungen werden zurückgesetzt. Das Training macht später beim letzten Zwischenstand weiter. |
| **Remote-Modus Status** | Zeigt, ob der Remote-Modus an ist und ob gerade trainiert wird. |

Wichtig:
- **Sperren ist okay** (Windows-Taste + L), **abmelden nicht**. Nach dem Abmelden läuft nichts mehr.
- Der Rechner muss eingeschaltet sein. Ein Laptop muss am Netzteil hängen.
- Fürs Spielen einfach vorher **Remote-Modus AUS** klicken.

Die Einrichtung schaltet den Remote-Modus am Ende einmal ein, damit der Auftraggeber sie prüfen kann.

### Stromkosten
Jedes Training protokolliert den Stromverbrauch der Grafikkarte alle 5 Sekunden (`nvidia-smi`). Daraus rechnet der
Auftraggeber die kWh für die Abrechnung aus. CPU und Netzteil sind darin nicht enthalten.

### Wieder entfernen
1. **Remote-Modus AUS** klicken.
2. In PowerShell `wsl --unregister RemoteTraining` ausführen. Das löscht die Linux-Umgebung des Remote-Trainings, dein eigenes WSL bleibt.
3. Die Aufgaben „RemoteTraining Runner“ und gegebenenfalls „RemoteTraining Einrichtung fortsetzen“ in der Aufgabenplanung löschen.
4. Den Ordner `C:\RemoteTraining` und die drei Verknüpfungen löschen.
5. Gegebenenfalls die Zeile `memory=...` in `%UserProfile%\.wslconfig` entfernen. Eine Sicherung liegt daneben als `.wslconfig.vor_remotetraining`.

## Dateien

| Datei | Zweck |
|---|---|
| `inventar.ps1` | Schritt 1, liest nur aus |
| `start.ps1` | lädt dieses Repo nach `C:\RemoteTraining\setup` und startet die Einrichtung als Administrator |
| `einrichten.ps1` | die eigentliche Einrichtung; `-DryRun` zeigt nur an, was passieren würde |
| `wsl_einrichten.sh` | Trainingssoftware in der Linux-Umgebung (Version wie beim Auftraggeber) |
| `kohya_pakete.txt` | Paketliste dazu, wird vom Auftraggeber erzeugt |
| `remote_modus.ps1` | EIN / AUS / Status (die Desktop-Verknüpfungen) |
| `runner_start.ps1` | startet den GitHub-Runner bei der Anmeldung, wenn der Remote-Modus an ist |

Alle Skripte zeigen mit `Get-Help .\<datei>.ps1 -Full` ihre Hilfe.
