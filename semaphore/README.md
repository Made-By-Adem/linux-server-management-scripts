# Semaphore-playbooks

Ansible-playbooks om de bestaande scripts uit deze repository vanuit
[Semaphore UI](https://semaphoreui.com) te draaien. De playbooks herschrijven
niets: ze roepen dezelfde scripts aan die je anders met de hand op de server
start, met de vlaggen voor onbemand gebruik, en laten de volledige output in
Semaphore zien.

## Uitgangspunten

- **Eén host tegelijk.** Elke playbook draait standaard met `serial: 1`.
  Faalt een host, dan stopt de run en worden de overige hosts niet aangeraakt.
  Met `batch_size` kun je meer hosts per batch nemen.
- **Geen reboots.** Geen van de scripts herstart de server. `update-containers`
  herstart wel de containers die het bijwerkt (zie hieronder).
- **Root via SSH-sleutel.** De baseline zet SSH op poort 888 met
  `PermitRootLogin prohibit-password`; de voorbeeldinventory gebruikt daarom
  `ansible_user=root` en `ansible_port=888`.
- **Geen terminal.** De scripts zijn geschreven voor iemand achter een
  terminal. `tasks/run-script.yml` start ze zonder terminal (`setsid`, stdin
  `/dev/null`), zodat een vraag nooit blijft hangen maar op het standaardantwoord
  terugvalt. Welke vragen dat zijn staat per template hieronder.
- **Exitcode telt.** Een exitcode buiten de geaccepteerde codes laat de host
  falen, na het tonen van de volledige output. Bij elke exitcode behalve 0
  toont Ansible een regel `ASYNC FAILED`; dat is normaal; of de host faalt,
  bepaalt de taak daarna.
- **Eigen deadline.** Elk script wordt met `timeout` gestopt (exitcode 124)
  vlak voordat Ansible het opgeeft (maintenance 2 uur, update-baseline en
  update-containers 1 uur, self-check 30 minuten). Een run die als mislukt
  gemeld wordt, draait dus niet stiekem door op de host.
- **Hele inventory.** Zonder `target` draait een template op alle hosts in de
  inventory, één voor één. Gebruik per omgeving een eigen inventory, of zet
  `target`/`--limit` bij templates die diensten herstarten.
- **Generiek.** Echte hosts, adressen en groepsnamen horen in Semaphore (of in
  een lokale `inventory.ini`, die git negeert), nooit in deze repository.

## Vereisten op de host

- De baseline is geïnstalleerd met `server-baseline/install-script.sh`, en
  `update-baseline` heeft minstens één keer gedraaid. Dat maakt de commando's
  in `/usr/local/bin` aan waar de playbooks op leunen.
- De publieke sleutel van Semaphore staat in `/root/.ssh/authorized_keys`.
  Let op: een nieuwe sleutel is precies wat de security-watchdog en AIDE
  melden. Draai daarna `sudo security-watchdog --reset` en
  `sudo aide-refresh --reason 'semaphore key toegevoegd'`.
- Python 3 (standaard aanwezig op Ubuntu, Debian en Raspberry Pi OS).

## Templates

### `maintenance-cycle.yml` — onderhoudsronde

Draait `maintenance-cycle --reason ...` (zie `docs/COMMANDS.md`): checkout
pullen, `update-baseline`, rkhunter-propertydatabase, AIDE verversen,
`test-alerts.sh`, AIDE nogmaals verversen, self-check. Reken op 35-45 minuten
per host met AIDE en zo'n zeven Telegram-berichten per host. Het script doet
zelf geen `apt upgrade` en geen reboot.

Vereist `/usr/local/bin/maintenance-cycle`; het script moet vanuit de checkout
draaien, dus er wordt geen kopie meegestuurd. Ontbreekt het commando, dan faalt
de host met uitleg.

| Extra var | Standaard | Betekenis |
|---|---|---|
| `maintenance_reason` | `Semaphore maintenance <datum>` | Komt in het Telegram-record en `/var/log/aide-refresh-*.log` |
| `maintenance_pull` | `true` | `false` geeft `--no-pull` |
| `maintenance_test_alerts` | `true` | `false` geeft `--no-test` (dan ook geen tweede AIDE-refresh) |
| `maintenance_accept_rkhunter` | `false` | `true` geeft `--yes` |
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `1` | Hosts per batch |

Over `maintenance_accept_rkhunter`: de enige vraag in dit script is of de
huidige rkhunter-waarschuwingen als nieuwe baseline geaccepteerd worden
(`rkhunter --propupd`). Zonder terminal wordt die vraag geweigerd, en dan meldt
de rkhunter-scan van 03:00 de binaries die een `apt upgrade` vervangen heeft.
Met `true` accepteert de run ze ongezien — op een gecompromitteerde host maakt
dat de compromittering de baseline. Zet het alleen aan als je de waarschuwingen
niet wilt lezen en dat risico bewust neemt.

`update-baseline` wordt door dit script zonder `--yes` aangeroepen. Zonder
terminal vallen de vragen daarin terug op hun standaard, wat neerkomt op
hetzelfde als `--yes` (zie hieronder). Eén uitzondering: heeft de host
helemaal geen Telegram-gegevens, dan vraagt `update-baseline` erom, breekt af
omdat er geen antwoord komt, en faalt de host. Vul ze eerst met de hand in
(`sudo update-baseline` op de host).

Geen dry-run: het script heeft er geen.

### `update-baseline.yml` — baseline bijwerken

Draait `update-baseline --yes`: detecteert bekende problemen en past de fixes
toe. Pullt de checkout niet; dat doet de onderhoudsronde.

| Extra var | Standaard | Betekenis |
|---|---|---|
| `dry_run` | `false` | `--dry-run`: laat zien wat elke fix zou doen |
| `check_only` | `false` | `--check`: alleen detecteren |
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `1` | Hosts per batch |

Twee vragen lezen ook met `--yes` van de terminal en vallen hier dus terug op
hun standaard: de cloudflared-container wordt **niet** opnieuw aangemaakt, en
de DOCKER-USER-firewallfix houdt precies de poorten open die op dat moment
gepubliceerd zijn. Ontbreken de Telegram-gegevens, dan wordt dat gemeld in
plaats van gevraagd.

Een fix kan diensten herstarten (fail2ban, auditd) en kan de AIDE-baseline
opnieuw opbouwen (10-20 minuten). Begin op een nieuwe host met
`check_only=true`.

### `update-containers.yml` — containers bijwerken

Draait `update-containers --unattended`: nieuwe image pullen en elke
compose-container opnieuw aanmaken. **Elke container ligt daarbij kort stil;
dit is een herstart van de diensten op die host.** De AIDE-baseline wordt niet
ververst (zoals het script in onbemande modus bedoelt); de onderhoudsronde doet
dat wel.

Gebruikt `/usr/local/bin/update-containers` als dat bestaat, anders wordt het
script uit deze checkout naar een tijdelijke map op de host gekopieerd.

| Extra var | Standaard | Betekenis |
|---|---|---|
| `dry_run` | `false` | `--dry-run`: alleen tonen wat er zou gebeuren |
| `update_system` | `false` | `--update-system`: eerst `apt-get upgrade` |
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `1` | Hosts per batch |

### `security-selfcheck.yml` — self-check (alleen lezen)

Draait `security-selfcheck` en verandert niets. Exitcode 0 = alles in orde,
1 = minstens één FAIL (host faalt), 2 = alleen waarschuwingen (host slaagt,
tenzij `fail_on_warnings=true`).

Gebruikt de geïnstalleerde `/usr/local/bin/security-selfcheck.sh`, want die weet
waar de Telegram-gegevens staan. Ontbreekt die, dan wordt het script uit deze
checkout gekopieerd; die kopie controleert gewoon, maar vindt de
Telegram-gegevens mogelijk niet.

| Extra var | Standaard | Betekenis |
|---|---|---|
| `selfcheck_deep` | `false` | `--deep`: ook een echte `aide --check` (10-20 min) |
| `selfcheck_telegram` | `false` | `--telegram`: fouten naar Telegram |
| `fail_on_warnings` | `false` | Exitcode 2 telt als fout |
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `1` | Hosts per batch |

### Niet opgenomen

`backup-script/backup.sh` heeft per host een eigen `.env` met een externe
bestemming nodig. Dat is geen generieke template; draai het via de bestaande
cron of met de hand.

## Semaphore inrichten

1. **Key Store**: een SSH-sleutel (type *SSH Key*, login `root`).
2. **Repository**: deze repository, branch `main`.
3. **Inventory**: *Static*, gebaseerd op `inventory.example.ini`, met de
   SSH-sleutel uit stap 1. Neem de regels onder `[all:vars]` over: Semaphore
   draait `ansible-playbook` vanuit de root van de repository en leest
   `semaphore/ansible.cfg` dus niet.
4. **Task Templates**: één per playbook, met als pad bijvoorbeeld
   `semaphore/maintenance-cycle.yml`. Extra vars zet je in de template of bij
   het starten van een taak (JSON, bijv. `{"dry_run": true}`).

### Schema (suggestie)

- `security-selfcheck.yml`: dagelijks, bijv. `30 7 * * *`. Alleen lezen, dus
  veilig om in te plannen.
- `maintenance-cycle.yml`: wekelijks in de nacht, bijv. zondag `0 1 * * 0`.
  Draait host voor host; met zes hosts reken je op 4-5 uur. Plan de AIDE- en
  rkhunter-crons (03:00 en 05:00) niet tegelijk met een lopende ronde, of
  begin vroeg genoeg. Verschillende omgevingen kun je op verschillende nachten
  zetten.
- `update-containers.yml` en `update-baseline.yml`: liever niet inplannen;
  draai ze bewust, eerst met `dry_run=true`.
- `test-alerts.sh` niet los inplannen (zie `docs/COMMANDS.md`); de
  onderhoudsronde draait het al.

## Lokaal testen

```bash
cd semaphore
cp inventory.example.ini inventory.ini   # vul echte hosts in
ansible-playbook --syntax-check maintenance-cycle.yml
ansible-playbook security-selfcheck.yml --limit server1.example.com
```
