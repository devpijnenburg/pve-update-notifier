# PVE Update Notifier

Dagelijkse check op openstaande (security-)updates op je Proxmox-host en in alle LXC's.
Het resultaat gaat via MQTT naar Home Assistant, en daarvandaan naar Telegram.

## Installeren (per Proxmox-host, als root)

Zet `pve-update-notifier.sh` in een GitHub-repo en draai dan:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/pve-update-notifier.sh)"
```

Of kopieer het bestand naar de host en draai `bash pve-update-notifier.sh`.

De installer:
1. installeert `jq` en `mosquitto-clients`
2. vraagt om de MQTT-broker, de login en het tijdstip (standaard 18:00) en test de verbinding
3. zet het check-script in `/usr/local/sbin/pve-update-check.sh`
4. maakt een systemd-timer aan (`pve-update-check.timer`)
5. draait desgewenst direct een eerste check

Draai je hetzelfde commando nog een keer, dan krijg je een menu met deze opties: script updaten,
configuratie wijzigen, nu checken, status tonen en verwijderen.

## Nieuwe en verwijderde containers
- **Nieuw:** bij elke run haalt het script `pct list` opnieuw op. Een nieuwe container wordt dus
  bij de eerstvolgende run gecheckt en krijgt in HA automatisch een eigen device.
  Er is niets aan te passen.
- **Verwijderd:** het script onthoudt welke containers het kent (`/var/lib/pve-update-check/known`).
  Is een container weg, dan worden de sensoren uit HA verwijderd. In het rapport zie je dan "🗑 container X bestaat niet meer".
- **Gestopt:** wordt niet gecheckt, maar de sensoren blijven bestaan met de laatst bekende waarde.
  In het bericht staat de container onder "⏸ niet gecheckt".

## Home Assistant
- Per container een device met de sensoren **Updates** en **Security-updates**.
  Het attribuut `packages` bevat de lijst; `[S]` betekent security.
- Automation **"Proxmox: updates beschikbaar via Telegram"** luistert op `pve-updates/+/report`.
  Security-updates komen binnen met geluid, de rest stil.

## Grenzen
- Checkt apt (Debian/Ubuntu) en apk (Alpine). Er wordt niets geïnstalleerd.
- VM's en Docker-images binnen een LXC vallen erbuiten (daarvoor: What's Up Docker of Diun).
