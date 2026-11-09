---
title: Ultra-schlankes Windows-11-Image bauen
sidebar_label: Ultra-schlankes Windows 11
sidebar_position: 7
description: Baue unter NixOS ein schlankes, unbeaufsichtigtes Windows-11-ISO mit wimlib, xorriso und einem Debloat-Skript für den ersten Start.
---

import Link from '@docusaurus/Link';

# Ultra-schlankes Windows-11-Image bauen

Du kannst unter NixOS ein eigenes Windows-11-ISO bauen – ohne DISM und ohne
Windows-Build-Rechner. Das Toolkit in [`windows/`](https://github.com/403access/nixos/tree/main/windows)
entpackt das ISO, wendet eine Edition an, injiziert eine unbeaufsichtigte
Installation, entfernt beim ersten Start Consumer-Apps und Telemetrie,
komprimiert die WIM neu und packt ein bootfähiges ISO.

:::danger
Das ist ein nicht unterstützter Weg, Windows zu installieren. Ein stark
abgespecktes Image kann Windows Update, Treiber, .NET, den Store, die
Wiederherstellung oder künftige Feature-Updates beschädigen. Teste das ISO
immer zuerst in einer virtuellen Maschine, behalte eine funktionierende
Windows-Installation und Rettungsmedien, und verwende kein leeres Passwort auf
einem Gerät, das ein Netzwerk erreichen kann.
:::

## Was „schlank“ hier bedeutet

Es gibt drei unabhängige Ebenen. Wenn du sie trennst, wird das Ergebnis deutlich
zuverlässiger, als einfach Ordner aus einer gemounteten WIM zu löschen:

1. **Installationsmedium** — ISO entpacken, eine Edition auswählen, Caches
   bereinigen, `install.wim` neu komprimieren und die Boot-Records neu bauen.
2. **Unbeaufsichtigte Installation** — lokaler Administrator, kein
   Microsoft-Konto und optional das Umgehen der Prüfungen für TPM, Secure Boot,
   RAM, CPU und Speicher.
3. **Debloat beim ersten Start** — provisionierte AppX-Pakete entfernen und
   Policy-Werte setzen, nachdem Windows Setup gelaufen ist.

NixOS eignet sich hervorragend für Ebene 1 und kann Ebene 2 und 3 vorbereiten.
NixOS kann DISM nicht offline ausführen. Echte Komponenten-Bereinigung
(Defender, WinSxS, optionale Features, Sprachpakete) braucht deshalb weiterhin
eine Windows-VM mit DISM, NTLite oder MSMG Toolkit. Dieser fortgeschrittene Weg
wird weiter unten beschrieben.

## Was du bekommst

| Profil | Entfernt | Behält | Gedacht für |
| --- | --- | --- | --- |
| `safe` | Setup-Caches, Logs, temporäre Dateien; neu komprimierte WIM | Alles andere | Alltag, maximale Kompatibilität |
| `lean` | Consumer-AppX, Telemetrie-Dienste/-Tasks, Consumer-Vorschläge, Copilot-Policies | Store, Defender, Windows Update, OneDrive | Empfohlen |
| `micro` | `lean` + Store, Xbox, OneDrive, Suchindex, SysMain, optional WinRE | Defender und Windows Update | Experimentell; braucht `--experimental` |

Der belegte Speicher hängt von Windows-Build, Treibern und Profil ab. Eine
`lean`-Installation liegt häufig bei 8–12 GB auf der Platte, `micro` darunter.
Behandle keine Zahl als Garantie. 1–2 GB RAM im Leerlauf sind mit aggressiver
Bereinigung möglich, aber kein unterstütztes Ziel.

`lean` und `micro` entfernen AppX-Pakete erst beim ersten Start, deshalb enthält
die `install.wim` sie weiterhin. Das installierte System wird kleiner, nicht
zwingend das ISO. Für ein kleineres ISO kommen `--solid` und `--remove-winre`
oder Offline-Entfernen mit DISM/NTLite infrage, wie unten beschrieben.

## Voraussetzungen

- Ein legal erworbenes Windows-11-x64-ISO (zum Beispiel von der
  Microsoft-Downloadseite). Das Toolkit lädt Windows nicht herunter und
  aktiviert es nicht.
- NixOS oder ein anderes Linux mit `wimlib`, `p7zip`, `xorriso` und `python3`.
  Das mitgelieferte `windows/shell.nix` bringt alles mit.
- Etwa 20 GB freien Speicher. Solid-Kompression braucht temporär mehr.
- Eine virtuelle Maschine zum Testen. Unter NixOS ist QEMU/KVM mit
  `virt-manager` eine gute Wahl; Windows Setup braucht keine VirtIO-Treiber,
  wenn du für die Testplatte IDE/SATA verwendest.

## Schnellstart

Im Repository-Stamm:

```bash
cd windows
nix-shell
./build-win11.sh --iso ~/Downloads/Win11_24H2_German_x64.iso --profile lean --locale de-DE
```

Das Skript gibt das erzeugte lokale Passwort aus. Speichere es, bevor du das
Terminal schließt, oder übergib dein eigenes Passwort mit `--password`.

Ein konservatives Image:

```bash
./build-win11.sh --iso ~/Downloads/Win11.iso --profile safe
```

Ein experimentelles Micro-Image:

```bash
./build-win11.sh \
  --iso ~/Downloads/Win11.iso \
  --profile micro \
  --experimental \
  --solid \
  --remove-winre \
  --locale de-DE
```

Das Ergebnis landet in `windows/out/`, mit einer `.sha256`-Datei daneben.

## So funktioniert der Build

```text
Windows-ISO
    │
    ├─ 7z entpacken ───────────────────────────► ISO-Baum
    │                                              │
    │                                              ├─ sources/install.wim (oder .esd)
    │                                              │        │
    │                                              │        ├─ wimlib apply
    │                                              │        ├─ Caches / optional WinRE löschen
    │                                              │        ├─ autounattend.xml injizieren
    │                                              │        ├─ sources/$OEM$/$$/Setup/Scripts injizieren
    │                                              │        ├─ wimlib capture
    │                                              │        └─ optionale Solid-Kompression
    │                                              │
    │                                              └─ xorriso ──► bootfähiges ISO
    │
    └─ autounattend.xml + SetupComplete.ps1
```

Das Skript verwendet absichtlich `wimlib-imagex apply` und `capture` statt eines
Read-Write-Mounts. Das funktioniert unter NixOS und macOS, vermeidet FUSE und
macht Fehler leichter nachvollziehbar.

:::note
wimlib ist kein unterstütztes Windows-Servicing-Werkzeug. Es erhält Dateiinhalte
und WIM-Metadaten, aber Windows-ACLs und Security Descriptors können sich von
einem mit DISM gewarteten Image unterscheiden. Prüfe Berechtigungen und
Windows-Update-Verhalten in einer VM, bevor du ausrollst.
:::

Wenn du ein Image unter Linux interaktiv anschauen willst:

```bash
sudo wimmountrw install.wim 6 /mnt/win11
# ... Dateien unter /mnt/win11 bearbeiten ...
sudo wimunmount /mnt/win11 --commit
```

Lösche in diesem Mount **nicht** mit `rm -rf` unter
`Program Files\WindowsApps`. Die AppX-Provisioning-Datenbank und die
Paketdateien müssen synchron bleiben. Entferne Pakete über
`Remove-AppxProvisionedPackage`, so wie es das First-Boot-Skript macht.

## Schritt 1: ISO besorgen und prüfen

Lade Windows 11 von Microsoft oder einer vertrauenswürdigen Quelle. Das Media
Creation Tool von Microsoft läuft nur unter Windows; nutze unter NixOS den
direkten ISO-Download oder einen vertrauenswürdigen Mirror. Prüfe den Hash,
bevor du etwas veränderst:

```bash
sha256sum ~/Downloads/Win11.iso
# mit dem veröffentlichten Wert der Quelle vergleichen
```

Wenn dein Download eine ESD-Datei ist oder das ISO `sources/install.esd`
enthält, konvertiert das Skript sie mit wimlib nach `install.wim`. Gesplittete
`install*.swm`-Images werden nicht automatisch unterstützt; führe sie vorher mit
`wimlib-imagex join` zusammen.

## Schritt 2: Build-Shell starten

```bash
cd windows
nix-shell
```

Die Shell stellt `wimlib-imagex`, `7z`, `xorriso`, `python3`, `hivex` und
`chntpw` bereit. Wenn du lieber eine einmalige Shell möchtest:

```bash
nix-shell -p wimlib p7zip libisoburn python3
```

## Schritt 3: Edition auswählen

Das Skript erkennt `Windows 11 Pro` automatisch und listet alle Images auf:

```text
Index:                  6
Name:                   Windows 11 Pro
```

Indizes unterscheiden sich je nach Release und Sprache. Wenn die automatische
Erkennung fehlschlägt, liste die Images auf und übergib den Index explizit:

```bash
wimlib-imagex info /path/to/install.wim
./build-win11.sh --iso Win11.iso --profile lean --index 6
```

Nach dem Build enthält die neue WIM genau ein Image. Deshalb verweist
`autounattend.xml` auf Index `1`. Das erledigt das Skript automatisch.

## Schritt 4: Unbeaufsichtigte Installation verstehen

Nutze eine Locale, die im Quell-ISO vorhanden ist. `--locale de-DE` auf einem
rein englischen ISO kann auf Englisch zurückfallen oder das Setup scheitern
lassen; lade vorher das passende Sprachimage herunter.

Die erzeugte `autounattend.xml` macht vier Dinge:

- sie setzt Setup-Sprache und Locale;
- sie wählt den Image-Index;
- sie legt einen lokalen Administrator an und blendet die
  Microsoft-Konto-Bildschirme aus;
- sie umgeht optional die Prüfungen für TPM 2.0, Secure Boot, RAM, CPU und
  Speicher.

Die Hardware-Prüfungen werden über die bekannten `LabConfig`-Registry-Werte
umgangen:

```xml
<RunSynchronousCommand wcm:action="add">
  <Order>1</Order>
  <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
</RunSynchronousCommand>
```

Füge `BypassSecureBootCheck`, `BypassRAMCheck`, `BypassCPUCheck` und
`BypassStorageCheck` auf dieselbe Weise hinzu. Microsoft ändert diese Prüfungen
zwischen Releases. Teste genau den Build, den du einsetzen willst.

Die erzeugte Datei legt standardmäßig ein lokales Konto mit zufälligem Passwort
an. Das ist Absicht: ein leeres Administrator-Passwort plus Auto-Logon ist eine
Laborbequemlichkeit, keine Sicherheitsstrategie. Nutze `--password` für ein
eigenes Passwort und `--autologon` nur in einer Wegwerf-VM.

Die Datenträgerauswahl bleibt interaktiv. Das Skript rät nie, welche Platte
gelöscht werden soll. Wenn du ein vollständig unbeaufsichtigtes Plattenlayout
willst, ergänze `InstallTo` mit der richtigen `DiskID` und `PartitionID` in
deiner eigenen `autounattend.xml` und übergib sie mit `--unattend`. Der Build
nimmt die gewählte Edition als Ein-Image-WIM neu auf, deshalb muss eine eigene
Antwortdatei auf `/IMAGE/INDEX` `1` verweisen.

:::warning
Der Hardware-Bypass ist keine Erlaubnis, Windows 11 auf Hardware zu betreiben,
die Microsoft nicht unterstützt. Treiber-, Firmware- und Update-Probleme liegen
in deiner Verantwortung.
:::

## Schritt 5: Debloat beim ersten Start

Für `lean` und `micro` injiziert der Build:

```text
sources/$OEM$/$$/Setup/Scripts/SetupComplete.cmd
sources/$OEM$/$$/Setup/Scripts/SetupComplete.ps1
```

Windows kopiert diese Dateien nach `C:\Windows\Setup\Scripts` und führt
`SetupComplete.cmd` einmal nach dem Setup aus. Das PowerShell-Skript:

- entfernt provisionierte AppX-Pakete mit `Remove-AppxProvisionedPackage`;
- entfernt installierte Pakete mit `Remove-AppxPackage -AllUsers`;
- deaktiviert Telemetrie-Dienste und geplante Aufgaben;
- setzt Policy-Werte für Telemetrie, Consumer-Features, Cortana, Copilot,
  Recall, Aktivitätsverlauf und Delivery Optimization.

Die AppX-Liste steht in `windows/scripts/SetupComplete.ps1`. Bearbeite die
Arrays `$leanPatterns` oder `$microPatterns`, wenn du eine App behalten oder
entfernen willst. Paketnamen ändern sich zwischen Windows-Releases; das Skript
protokolliert jeden Fehler und macht weiter, statt das Setup abzubrechen.

`lean` behält Store, Defender, Windows Update und OneDrive. `micro` entfernt
Store, Xbox, OneDrive, Suchindex und SysMain. Wer den Store entfernt, verliert
auch den normalen Weg, paketierte Apps zu installieren und zu aktualisieren.
Halte `winget` und einen Browser-Installer bereit, wenn du `micro` wählst.

## Schritt 6: Bauen und testen

Baue das ISO und teste es, bevor du es auf einen USB-Stick schreibst:

```bash
qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 4 -cpu host \
  -drive file=win11-test.qcow2,if=ide,format=qcow2 \
  -cdrom windows/out/Win11-lean-*.iso \
  -boot d
```

Erzeuge die Platte vorher, falls nötig:

```bash
qemu-img create -f qcow2 win11-test.qcow2 40G
```

Auf einer Maschine ohne KVM entferne `-enable-kvm -cpu host`; der Test wird
langsam, bleibt aber nützlich.

Schreibe das ISO erst auf einen USB-Stick, nachdem die VM gebootet und
installiert hat:

```bash
lsblk
sudo dd if=windows/out/Win11-lean-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Ersetze `/dev/sdX` durch die **gesamte Platte**, nicht durch eine Partition.
Das zerstört das Zielgerät. Ventoy und ähnliche Werkzeuge sind für
Wechselmedien weniger fehleranfällig.

Das ISO verwendet ISO-Level 3, deshalb kann `install.wim` größer als 4 GiB sein.
Das ist für `dd` und Ventoy kein Problem, aber für einen manuell vorbereiteten
FAT32-Stick. Wenn du FAT32 brauchst, überspringe `--solid` und teile die WIM mit
`wimlib-imagex split`; behalte die `.swm`-Dateien in `sources/`. Solid
komprimierte WIMs lassen sich nicht splitten.

## Schritt 7: Installiertes System prüfen

Prüfe vor dem Ausrollen mindestens:

- UEFI-Boot funktioniert (und BIOS/CSM, falls noch nötig).
- Das lokale Konto meldet sich an; kein Microsoft-Konto wird verlangt.
- Netzwerk, Audio, GPU, Sleep und USB funktionieren.
- Windows Update kann ein Update herunterladen und installieren (bei `safe` und
  `lean`).
- Store und `winget` funktionieren (bei `lean`; `micro` entfernt den Store
  absichtlich).
- Defender ist vorhanden und aktualisiert sich (sofern nicht bewusst entfernt).
- Ein Browser, 7-Zip, .NET und deine tatsächlichen Anwendungen starten.
- `sfc /scannow` und, wenn der Servicing-Stack intakt ist,
  `DISM /Online /Cleanup-Image /RestoreHealth` laufen erfolgreich durch.
- Die Ereignisanzeige zeigt nach dem ersten Start keine wiederkehrenden
  kritischen Fehler.

Wenn Windows Update nach aggressiver Bereinigung fehlschlägt, ist meist eine
entfernte Servicing-Komponente oder ein fehlendes Sprach-/Feature-Paket die
Ursache. Stelle das Original-Image wieder her, statt den Schaden zu reparieren.

## Was entfernt wird und was bleibt

Ein `lean`- oder `micro`-Image behält normalerweise:

- NT-Kernel, HAL, Win32-Subsystem, WinUI und den klassischen Desktop;
- Explorer, Task-Manager, Systemsteuerung, CMD und PowerShell;
- Netzwerk-, Speicher-, GPU- und Eingabetreiber aus dem Quell-Image;
- Win32-Anwendungen wie Firefox, 7-Zip, Notepad++ oder portable Tools;
- Defender und Windows Update (sofern du nicht mit DISM/NTLite über `micro`
  hinausgehst).

Es verliert normalerweise:

- Consumer-AppX-Pakete: Xbox, Zune, Ihr Smartphone, News, Wetter, Solitaire,
  Clipchamp, Teams Consumer, Office Hub, Mail/Kalender und Ähnliches;
- Telemetrie-Dienste und geplante Aufgaben;
- Consumer-Vorschläge, Cortana-Websuche, Copilot-/Recall-Policies;
- Store, Suchindex und OneDrive in `micro`;
- WinRE, wenn du `--remove-winre` übergibst.

Was dieses Toolkit **nicht** entfernt:

- Windows Defender (Deaktivieren ist nicht Entfernen);
- Windows Update oder den CBS/DISM-Servicing-Stack;
- WinSxS (niemals manuell löschen);
- Edge/WebView2 (viele Anwendungen hängen von WebView2 ab);
- Sprachpakete und optionale Features (dafür DISM in einer Windows-VM nutzen).

Ab diesen Änderungen wird „ultra-schlank“ nicht mehr unterstützt. Wenn du den
Servicing-Stack entfernst, ist das Image praktisch auf dem Build eingefroren,
und kumulative Updates schlagen fehl. Wenn du Defender entfernst, bist du für
Endpoint-Sicherheit selbst verantwortlich. Wenn du WinSxS oder den Component
Store entfernst, können `sfc` und `DISM /RestoreHealth` das System nicht mehr
reparieren.

## Fortgeschritten: echtes Offline-Entfernen von Komponenten

Wenn du Defender, Edge, optionale Features, Sprachpakete oder Komponenten
entfernen willst, bevor Setup läuft, brauchst du eine Windows-Umgebung für das
Servicing:

1. Erstelle eine Windows-11-VM mit QEMU/KVM, VirtualBox oder VMware.
2. Hänge den entpackten ISO-Baum oder die `install.wim` ein.
3. Nutze DISM offline:

   ```powershell
   dism /Mount-Image /ImageFile:C:\Win11\sources\install.wim /Index:6 /MountDir:C:\Mount
   dism /Image:C:\Mount /Get-ProvisionedAppxPackages
   dism /Image:C:\Mount /Remove-ProvisionedAppxPackage /PackageName:<name>
   dism /Unmount-Image /MountDir:C:\Mount /Commit
   ```

4. Oder nutze NTLite (GUI) / MSMG Toolkit (Batch) in dieser VM.
5. Kopiere die geänderte `install.wim` zurück in den NixOS-Build-Baum oder baue
   das ISO mit demselben `xorriso`-Befehl neu.

DISM ist die unterstützte Servicing-Engine. wimlib kann die WIM lesen und
schreiben, ersetzt aber nicht die Logik des Component Store. Deshalb entfernt
das Standard-Toolkit Apps beim ersten Start, statt Offline-Servicing
vorzutäuschen.

## GUI- und Batch-Alternativen

Wenn du die Image-Chirurgie lieber auf einem Windows-Host oder in einer
Windows-VM machst, sind NTLite und MSMG Toolkit die zwei etablierten Werkzeuge.
Sie können Komponenten entfernen, die wimlib nicht sicher warten kann. Beide
brauchen weiterhin ein legal erworbenes ISO und eine Testmaschine.

### NTLite

NTLite ist der GUI-Standard für Offline-Windows-Modifikation. Die kostenlose
Edition deckt einfaches Trimmen ab; die bezahlten Editionen schalten tieferes
Entfernen von Komponenten frei.

1. Entpacke das ISO in einen kurzen Pfad wie `C:\Win11ISO`.
2. Starte NTLite, füge den entpackten Ordner hinzu und wähle die Edition.
3. **Components** — entferne Consumer-AppX (Xbox, Zune, Ihr Smartphone, Get
   Started, Solitaire, Wetter, News) und optionale Features wie Cortana,
   Internet Explorer/Legacy Edge, Sprache und Telemetrie. Entferne nicht WinSxS,
   den Netzwerk-Stack, Storage-Controller oder den Grafik-Stack.
4. **Updates / Drivers** — integriere das neueste kumulative Update und die
   NVMe-/Chipsatz-/Storage-Treiber, die du brauchst.
5. **Unattended / Settings** — deaktiviere Telemetrie und Cortana, umgehe den
   OneDrive-Setup-Druck und konfiguriere einen lokalen Administrator.
6. **Apply** — nutze *Save and Trim* oder *Create ISO*.
7. Teste das Ergebnis in einer VM, bevor du Hardware anfasst.

NTLite ist proprietär. Behalte die Preset-Datei und das Quell-ISO, damit der
Build reproduzierbar bleibt.

### MSMG Toolkit

MSMG Toolkit ist ein kostenloses, batch-basiertes Toolkit. Es ist weniger
poliert als NTLite, skriptet aber gut und gibt dir direkte Kontrolle.

1. Entpacke das Toolkit und lege das Windows-ISO in sein `Source`-Verzeichnis.
2. Starte `Start.cmd` als Administrator.
3. **Source (1)** — Quell-Image einlesen.
4. **Integrate (2)** — Treiber, Sprachpakete oder Updates hinzufügen.
5. **Remove (3)** — Metro-/AppX-Apps und Windows-Komponenten entfernen. Lass
   WinSxS, Servicing, Netzwerk und Storage in Ruhe.
6. **Customize (4)** — optionale Features aktivieren oder deaktivieren.
7. **Apply (5)** — Änderungen in `install.wim` committen.
8. **Target (6)** — bootfähiges ISO erstellen.

### Tiny11builder und Post-Install-Skripte

`tiny11builder` ist ein PowerShell-Skript, das eine kuratierte AppX-/Komponenten-
Liste entfernt. Es ist bequem, aber weiterhin eine nicht unterstützte
Modifikation. Lies das Skript, bevor du es ausführst, und teste genau den
Windows-Build.

Für das Finetuning nach der Installation kommen [Sophia Script for
Windows](https://github.com/farag2/Sophia-Script-for-Windows) oder das [Chris
Titus Tech Windows Utility](https://github.com/ChrisTitusTech/winutil) infrage.
Sie entfernen AppX-Reste, deaktivieren SysMain oder Telemetrie-Tasks und passen
Dienste an. Führe sie nicht blind auf einer Produktionsmaschine aus. Wenn du ein
wiederverwendbares Image brauchst, mache die Änderungen im Audit-Modus und
generalisiere die Installation mit `sysprep`; sonst ist das Ergebnis eine
Einmal-Installation.

| Ansatz | Läuft auf | Stärke | Nachteil |
| --- | --- | --- | --- |
| Dieses Toolkit | NixOS/Linux | Reproduzierbares ISO, Unattend, First-Boot-Debloat | Kein natives DISM-Component-Servicing |
| NTLite | Windows | Präzises GUI-Komponenten-Entfernen | Proprietär, schnell zu viel entfernt |
| MSMG Toolkit | Windows | Kostenlos, batch-orientiert | Alte UI, viele manuelle Schritte |
| tiny11builder | Windows | Schnelles Skript-Trimmen | Nicht unterstützt, buildabhängig |
| DISM in einer VM | Windows | Unterstützte Servicing-Engine | Langsam, braucht Windows-VM |

## Fehlerbehebung

| Symptom | Wahrscheinliche Ursache | Lösung |
| --- | --- | --- |
| Setup fragt nach Product Key | Kein Key und keine Edition ausgewählt | `--index` nutzen oder `--product-key` übergeben |
| Setup bleibt bei der Datenträgerauswahl stehen | `ImageInstall` hat kein `InstallTo` | Platte interaktiv wählen oder `InstallTo` in die eigene Antwortdatei aufnehmen |
| Setup fragt nach Microsoft-Konto | Unattend nicht gefunden/ignoriert | `autounattend.xml` ins ISO-Stammverzeichnis legen; nicht umbenennen |
| `0x80070570` während der Installation | Kaputte Extraktion oder ISO | Neu herunterladen, SHA-256 prüfen, ohne `--solid` neu bauen |
| Bootloop nach dem ersten Start | Schlechtes Unattend oder entfernte Systemkomponente | Mit `safe` neu bauen, dann Änderungen einzeln ergänzen |
| Store fehlt | `micro`-Profil | `lean` verwenden oder Store nachinstallieren |
| Windows Update schlägt fehl | Servicing-Stack oder Component Store entfernt | Original-Image wiederherstellen; WinSxS nicht löschen |
| AppX-Entfernung meldet Fehler | Paketname in diesem Windows-Build geändert | Muster in `SetupComplete.ps1` anpassen; Fehler sind nicht fatal |
| `wimlib-imagex`-Berechtigungsfehler | ACLs bei Apply ohne Root | Als Root bauen oder akzeptieren, dass ACLs nicht erhalten bleiben |
| USB bootet nicht | Auf Partition geschrieben oder FAT32-Grenze | ISO auf die ganze Platte schreiben; Ventoy nutzen oder WIM splitten |

## Skript-Referenz

| Option | Zweck |
| --- | --- |
| `--iso PATH` | Quell-Windows-11-ISO. Erforderlich. |
| `--profile safe\|lean\|micro` | Debloat-Stufe. Standard `lean`. |
| `--out PATH` | Pfad des Ausgabe-ISOs. |
| `--index N` | Index der Quell-WIM. Standard: Windows 11 Pro automatisch erkennen. |
| `--locale de-DE` | Setup-Sprache und Locale. |
| `--input-locale VALUE` | Input-Locale, falls deine Locale nicht in der eingebauten Map steht, z. B. `0407:00000407`. |
| `--user NAME` | Name des lokalen Administrators. Standard `Admin`. |
| `--password VALUE` | Lokales Passwort. Standardmäßig wird ein zufälliges erzeugt. |
| `--allow-empty-password` | Leeres Passwort ausdrücklich erlauben. Nicht empfohlen. |
| `--autologon` | Einmaliges Auto-Logon. Nur fürs Labor. |
| `--product-key KEY` | Optionaler Product Key. |
| `--computer-name NAME` | Optionaler Computername. |
| `--unattend PATH` | Eigene `autounattend.xml` verwenden. |
| `--no-unattend` | `autounattend.xml` komplett überspringen. |
| `--no-postinstall` | Debloat-Skript für den ersten Start überspringen. |
| `--remove-winre` | WinRE aus dem Image entfernen. |
| `--solid` | WIM mit Solid-Kompression verkleinern. Kleiner, langsamer. |
| `--experimental` | Für `micro` erforderlich. |
| `--workdir PATH` | Arbeitsverzeichnis. Standard `windows/work`. |
| `--keep-work` | Entpackten Baum zur Inspektion behalten. |
| `--force` | Vorhandenes Ausgabe-ISO überschreiben. |

## Rechtliches und Betrieb

- Windows ist lizenzierte Software. Ein modifiziertes ISO darf nicht
  weitergegeben werden.
- Ein modifiziertes Image wird von Microsoft nicht unterstützt. Behalte das
  Original-ISO und einen Rettungsplan.
- Backe keine Passwörter, Product Keys oder Tokens in ein öffentliches
  Repository. Die erzeugte `autounattend.xml` enthält das gewählte lokale
  Passwort.
- Teste mit genau dem Windows-Build, den du ausrollen willst. AppX-Namen,
  Setup-Verhalten und Hardware-Prüfungen ändern sich zwischen Releases.
- Wenn das Gerät aus einem Netzwerk erreichbar ist, nutze ein echtes Passwort,
  Festplattenverschlüsselung wo sinnvoll und einen unterstützten
  Sicherheits-Stack.

## Nächste Schritte

- <Link to="/docs/guides/desktop">Desktop-Profile</Link> — wähle den
  NixOS-Desktop für den Build-Host.
- <Link to="/docs/guides/configuration">Konfiguration</Link> — die übrigen
  NixOS-Optionen dieses Repositories.
- [`windows/README.md`](https://github.com/403access/nixos/blob/main/windows/README.md)
  — die kurze Befehlsreferenz.
