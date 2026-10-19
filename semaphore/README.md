# Semaphore-playbooks

Ansible-playbooks om de bestaande scripts uit deze repository vanuit
[Semaphore UI](https://semaphoreui.com) te draaien. De playbooks herschrijven
niets: ze roepen dezelfde scripts aan die je anders met de hand op de server
start, met de vlaggen voor onbemand gebruik, en laten de volledige output in
Semaphore zien.

## Uitgangspunten

- **Alle hosts tegelijk.** Elke playbook draait standaard op alle hosts van
  de inventory tegelijk (`serial: 100%`). Faalt een host, dan gaan de andere
  gewoon door; de recap (en bij de nieuwere templates een samenvatting aan het
  eind) laat per host zien hoe het ging. Wil je voorzichtiger, zet dan
  `batch_size` (bijv. `1` = één voor één, `2` = twee per keer); met batches
  stopt de run pas als alle hosts in een batch falen.
- **Uitzondering: `reboot.yml`** draait standaard één voor één en stopt de
  rotatie bij de eerste fout. Alle servers tegelijk herstarten haalt al hun
  diensten op hetzelfde moment offline. `batch_size` kan het bewust verhogen.
  `coolify-redeploy.yml` draait op één runner en deployt de lijst achter
  elkaar.
- **Alleen `reboot.yml` herstart servers.** Geen van de andere templates
  rebootet; `system-updates.yml` meldt alleen of een reboot nodig is.
  `update-containers` herstart wel de containers die het bijwerkt (zie
  hieronder).
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
  vlak voordat Ansible het opgeeft (maintenance 2 uur, update-baseline,
  update-containers, `apt-get upgrade` en aide-refresh 1 uur, self-check
  30 minuten). Een run die als mislukt
  gemeld wordt, draait dus niet stiekem door op de host.
- **Hele inventory.** Zonder `target` draait een template op alle hosts in de
  inventory. Gebruik per omgeving een eigen inventory, of zet
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
| `batch_size` | `100%` | Hosts per batch (`1` = één voor één) |

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
| `batch_size` | `100%` | Hosts per batch (`1` = één voor één) |

Twee vragen lezen ook met `--yes` van de terminal en vallen hier dus terug op
hun standaard: de cloudflared-container wordt **niet** opnieuw aangemaakt, en
de DOCKER-USER-firewallfix houdt precies de poorten open die op dat moment
gepubliceerd zijn. Ontbreken de Telegram-gegevens, dan wordt dat gemeld in
plaats van gevraagd.

Een fix kan diensten herstarten (fail2ban, auditd) en kan de AIDE-baseline
opnieuw opbouwen (10-20 minuten). Begin op een nieuwe host met
`check_only=true`.

### `update-containers.yml` — containers bijwerken

Draait `update-containers` met een vaste selectie per host: nieuwe image pullen
en de gekozen compose-containers opnieuw aanmaken. **Elke container ligt
daarbij kort stil; dit is een herstart van die diensten.** De AIDE-baseline
wordt niet ververst (zoals het script in onbemande modus bedoelt); de
onderhoudsronde doet dat wel.

Welke containers, bepaal je per host of groep in de inventory:

| Variabele | Standaard | Betekenis |
|---|---|---|
| `update_containers_only` | leeg | Alleen deze containers (`--only`). Lijst of kommagescheiden; globs mogen, bijv. `app-*` |
| `update_containers_exclude` | leeg | Deze containers nooit (`--exclude`). Wint van de only-lijst; handig als groepsvariabele |
| `update_containers_all` | `false` | `true` = alle draaiende containers behalve de uitgesloten (`--unattended`). Staat er ook een only-lijst, dan wint die |

**Veiligheid:** is `update_containers_only` leeg en `update_containers_all`
niet `true`, dan faalt die host met uitleg en verandert er niets. Een
vergeten variabele wordt dus nooit "werk alles bij".

Containers met het label `coolify.managed=true` slaat het script altijd over,
ook als ze in de only-lijst staan; Coolify werkt die zelf bij (zie
`coolify-redeploy.yml`). Een naam in de only-lijst die op de host niet draait,
geeft een waarschuwing in de samenvatting maar laat de host niet falen.

Voorbeeld (statische inventory, INI). Op de hostregel mag een lijst of een
kommastring; onder `[groep:vars]` leest Ansible alles als tekst, gebruik daar
een kommastring:

```ini
[production]
server1.example.com  update_containers_only="nginx,app-*"
server2.example.com  update_containers_all=true

[production:vars]
update_containers_exclude="db-*,*-worker"
```

Zet deze variabelen niet in de template of als extra var bij het starten:
extra vars gaan boven hostvariabelen en gelden dan voor elke host in de run.

Het script wordt altijd uit deze checkout naar een tijdelijke map op de host
gekopieerd en met `bash` gestart (de baseline mount `/tmp` als `noexec`). Zo
past het script altijd bij de vlaggen die de playbook meegeeft; een oudere
geïnstalleerde versie kent `--only` misschien nog niet.

| Extra var | Standaard | Betekenis |
|---|---|---|
| `dry_run` | `false` | `--dry-run`: alleen tonen wat er zou gebeuren |
| `update_system` | `false` | `--update-system`: eerst `apt-get upgrade` |
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `100%` | Hosts per batch (`1` = één voor één) |

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
| `batch_size` | `100%` | Hosts per batch (`1` = één voor één) |

### `coolify-redeploy.yml` — Coolify-resources opnieuw deployen

Draait op de Semaphore-runner zelf (`localhost`) en praat alleen met de
REST-API van Coolify v4; er wordt op geen enkele server ingelogd. Deployt de
applicaties en services uit `coolify_redeploy` één voor één, wacht tot elke
klaar is en stopt bij de eerste die faalt.

- **Applicatie:** `POST /api/v1/deploy` met `{"uuid": ..., "force": ...}`,
  daarna `GET /api/v1/deployments/<uuid>` tot de status `finished` is
  (`failed` of `cancelled-by-user` = fout). Docker-image-applicaties pullen hun
  image opnieuw; git-applicaties bouwen opnieuw vanaf hun branch.
- **Service:** `POST /api/v1/services/<uuid>/restart?latest=true`: nieuwste
  images pullen en de containers opnieuw aanmaken. (`/deploy` start een
  service alleen met de images die er al zijn.) Een service heeft geen
  deployment-record; de playbook wacht tot Coolify de service weer als
  `running:healthy` of `running:unknown` meldt. Coolify werkt die status met
  wat vertraging bij, dus dit is een redelijke maar geen harde controle.

| Var | Standaard | Betekenis |
|---|---|---|
| `coolify_url` | — | Basis-URL, bijv. `https://coolify.example.com` (verplicht) |
| `coolify_api_token` | — | API-token met deploy-recht (verplicht, als *secret*); valt terug op de omgevingsvariabele `COOLIFY_API_TOKEN` |
| `coolify_redeploy` | — | uuids of exacte namen, lijst of kommagescheiden (verplicht) |
| `dry_run` | **`true`** | Alleen opzoeken en tonen wat er zou gebeuren. `false` = echt deployen |
| `coolify_force_rebuild` | `false` | Applicaties: bouwen zonder cache |
| `coolify_pull_latest` | `true` | Services: nieuwste images pullen |
| `coolify_deploy_timeout` | `1800` | Seconden wachten per resource |
| `coolify_poll_interval` | `10` | Seconden tussen statuscontroles |
| `coolify_service_settle` | `60` | Seconden die een service krijgt om te stoppen voordat de playbook op "running" wacht |
| `coolify_validate_certs` | `true` | TLS-certificaat controleren |
| `coolify_allow_http` | `false` | Ook een `http://`-URL accepteren (token gaat dan onversleuteld over de lijn) |

Een naam die bij geen of bij meer dan één resource hoort, laat de run vooraf
falen, voordat er iets gedeployd is; gebruik dan de uuid. Het token komt nooit
in de output: elke API-aanroep draait met `no_log`, de taken erna tonen alleen
namen, uuids, statussen en de meldingen van Coolify.

Let op: een deploy is een herstart van die dienst. Deploy de Semaphore-service
zelf niet vanuit Semaphore; dan stopt de lopende taak halverwege.

Inrichten: een inventory met alleen `localhost ansible_connection=local`, en
een environment met `coolify_url` als variabele en `coolify_api_token` als
secret. Gebruik per Coolify-instantie een eigen environment (en template).


### `system-updates.yml` — systeem-updates (apt)

`apt-get update`, `apt-get upgrade --with-new-pkgs` en `apt-get autoremove`,
standaard op alle hosts tegelijk. Onbemand (`DEBIAN_FRONTEND=noninteractive`) en bestaande
configuratiebestanden blijven staan (`--force-confdef --force-confold`).
`--with-new-pkgs` installeert nieuwe afhankelijkheden (zoals een nieuwe
kernel) maar verwijdert niets. needrestart staat op *list*: het meldt welke
diensten nog oude bibliotheken gebruiken en herstart er zelf geen; het
installatiescript van een pakket kan zijn eigen dienst wel herstarten.

**Docker blijft staan.** Een upgrade van de Docker-engine of containerd
herstart alle containers op de host. Daarom worden `docker-ce`,
`docker-ce-cli`, `docker-ce-rootless-extras`, `containerd.io`, `docker.io`,
`containerd` en `runc` (voor zover geïnstalleerd) tijdens de run op *hold*
gezet en daarna weer vrijgegeven, ook als de run faalt. Pakketten die al op
hold stonden, blijven op hold. Welke pakketten deze run vasthoudt, staat eerst
in `/var/lib/server-baseline/system-updates-held`; wordt de run halverwege
afgebroken (verbinding weg, runner herstart), dan geeft de volgende run ze
eerst vrij. Docker zelf bijwerken doe je bewust met
`include_docker_packages=true`, op een moment dat alle containers even weg
mogen.

**Geen reboot.** Het rapport per host zegt of `/var/run/reboot-required`
bestaat en welke pakketten erom vragen. Herstarten doe je daarna met
`reboot.yml` (bijv. met `only_if_required=true`).

**Baselines bijwerken.** Is er iets veranderd, dan draaien daarna
`aide-refresh --reason "<reason>"` en `security-watchdog --reset`, als die
commando's op de host staan (anders een notitie in het rapport, geen fout).
Zo meldt de volgende AIDE-check of watchdog niet de upgrade zelf. aide-refresh
stuurt eerst de lijst van alles wat het opneemt (10-20 minuten).

| Extra var | Standaard | Betekenis |
|---|---|---|
| `dry_run` | `false` | Alleen `apt-get update` en `apt-get -s upgrade`: laat zien wat er bijgewerkt zou worden. Er wordt niets geïnstalleerd, vastgezet of ververst |
| `include_docker_packages` | `false` | `true` = Docker-engine en containerd ook bijwerken. **Herstart alle containers** |
| `post_refresh` | `true` | `false` = geen aide-refresh en watchdog-reset na afloop |
| `reason` | `Semaphore system updates <datum>` | Komt in het AIDE-record |
| `apt_timeout` | `3600` | Seconden voor de upgrade zelf |
| `docker_hold_packages` | zie boven | Welke pakketten op hold gaan |
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `100%` | Hosts per batch (`1` = één voor één) |

Het rapport per host (en aan het eind voor alle hosts samen): aantal
bijgewerkte, nieuwe en verwijderde pakketten, welke Docker-pakketten zijn
tegengehouden, of een reboot nodig is, en of aide-refresh en de watchdog-reset
gedraaid hebben. De volledige lijst `pakket oud -> nieuw` staat erboven.

Loopt een upgrade over de `apt_timeout`, dan wordt apt gestopt en kan dpkg
half klaar zijn; draai dan op de host `sudo dpkg --configure -a`.

### `aide-refresh.yml` — AIDE-baseline verversen

Draait `aide-refresh --reason "<reason>"`: eerst `aide --check`, dan het
volledige lijstje van wat er opgenomen wordt (Telegram en
`/var/log/aide-refresh-*.log`), dan pas de database bijwerken. 10-20 minuten
per host. Gebruik het na een bewuste wijziging (upgrade, deployment, nieuwe
SSH-sleutel), niet op een schema: een baseline die zichzelf ververst, neemt
inbraak op als het nieuwe normaal.

| Extra var | Standaard | Betekenis |
|---|---|---|
| `reason` | — | **Verplicht.** Leeg = de run faalt voordat er iets gebeurt |
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `100%` | Hosts per batch (`1` = één voor één) |

Vereist `aide-refresh` (geïnstalleerd door `update-baseline`); ontbreekt het,
dan faalt de host.

### `watchdog-reset.yml` — security-watchdog resetten

Draait `security-watchdog --reset`: de huidige toestand van alle bewaakte
units en monitors wordt de nieuwe baseline, zonder melding. Daarvoor toont de
run `security-watchdog --status` (per unit en monitor: nu en de baseline die
vervangen wordt); dat is precies wat de reset accepteert. De `reason` komt in
syslog (tag `security-watchdog`).

| Extra var | Standaard | Betekenis |
|---|---|---|
| `reason` | leeg | Reden voor in syslog (optioneel) |
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `100%` | Hosts per batch (`1` = één voor één) |

Vereist `security-watchdog` (geïnstalleerd door `update-baseline`).

### `reboot.yml` — herstarten, één voor één

Herstart de hosts **standaard één voor één** (`batch_size` = 1,
`any_errors_fatal`): reboot, wachten tot SSH terug is, controleren, pas dan de
volgende. Faalt er iets, dan stopt de hele rotatie en worden de overige hosts
niet herstart. Dat geldt ook voor een host die onbereikbaar is als hij aan de
beurt is: Ansible's `any_errors_fatal` stopt daar zelf niet op, dus de playbook
controleert vóór elke host of alle eerdere hosts klaar zijn, en stopt anders.
Dit is bewust de enige template die niet standaard alle hosts
tegelijk doet: alles tegelijk herstarten haalt alle diensten op hetzelfde
moment offline. Met `batch_size` (bijv. `2`) kan het sneller; een fout stopt
dan nog steeds de batches erna.

Veiligheid:

- **`confirm_reboot` moet `yes` zijn** (de tekst). Alles anders laat de run
  falen voordat er op welke host dan ook iets gebeurt.
- **`reboot_refuse_hosts`**: hosts in deze lijst worden nooit herstart, maar
  overgeslagen met een duidelijke melding. Zet hier de host op waar Semaphore
  zelf draait: die herstarten breekt de lopende taak halverwege af. De
  vergelijking negeert hoofdletters en kijkt naar de inventorynaam, de korte
  naam en `ansible_host`. Een naam die op geen enkele host in de run past,
  geeft een waarschuwing (tikfout?). Zet de
  lijst in de template of environment, niet bij het starten.
- **`only_if_required=true`** slaat hosts zonder `/var/run/reboot-required`
  over.
- **`dry_run=true`** doet alle controles en laat zien waarop gewacht zou
  worden, zonder te herstarten (dan is `confirm_reboot` niet nodig).
- **Niet inplannen.** Deze template is bedoeld om door een mens gestart te
  worden; maak er geen schedule voor.

Controle na de boot:

- Docker antwoordt weer (als Docker geïnstalleerd is).
- Elke container die vóór de reboot draaide (op naam) draait weer, behalve die
  in `reboot_ignore_containers`. Een container zonder restart-policy komt niet
  vanzelf terug; dat laat de host bewust falen.
- De systemd-dienst `cloudflared` is weer actief, als hij dat vóór de reboot
  was. Een cloudflared-container valt onder de containercontrole.

| Extra var | Standaard | Betekenis |
|---|---|---|
| `confirm_reboot` | leeg | **Moet `yes` zijn** |
| `reboot_refuse_hosts` | leeg | Inventorynamen die nooit herstart worden (lijst of kommagescheiden) |
| `only_if_required` | `false` | Alleen hosts met `/var/run/reboot-required` |
| `dry_run` | `false` | Alleen controleren en tonen |
| `reason` | `Reboot via Semaphore` | Tekst in de shutdown-melding |
| `reboot_timeout` | `900` | Seconden wachten tot SSH terug is |
| `reboot_wait_timeout` | `600` | Seconden wachten op Docker, containers en cloudflared na de boot |
| `reboot_ignore_containers` | leeg | Containernamen waarop niet gewacht wordt |
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `1` | Hosts die samen herstart worden |

Na een reboot melden de security-watchdog (`boot-id`) en mogelijk AIDE de
herstart; dat is bedoeld. Draai zo nodig daarna `watchdog-reset.yml`.

### `status.yml` — status-overzicht (alleen lezen)

Verzamelt per host een kort gezondheidsbeeld en verandert niets (geen
`apt update`, geen herstarts, geen baselines).

Per host: uptime en load, geheugen, schijfgebruik van `/` en van de
Docker-root, of een reboot nodig is, hoeveel apt-upgrades klaarstaan (volgens
de pakketlijsten zoals ze zijn, met hun datum), de containers (naam, status,
image; niet-draaiende en unhealthy apart genoemd) en de stand van de
security-watchdog en AIDE als die geïnstalleerd zijn. Een onderdeel dat niet
te lezen is, staat als "unreadable" in het overzicht; de host faalt daar niet
op. Aan het eind volgt één compact overzicht van alle hosts.

| Extra var | Standaard | Betekenis |
|---|---|---|
| `target` | `all` | Inventorygroep of hostpatroon |
| `batch_size` | `100%` | Hosts per batch |

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
5. **Coolify redeploy** (optioneel): inventory *Static* met
   `localhost ansible_connection=local`, een environment met `coolify_url` en
   het secret `coolify_api_token`, en een template voor
   `semaphore/coolify-redeploy.yml`. Een survey-variabele `coolify_redeploy`
   laat je bij elke start kiezen wat er gedeployd wordt.

### Schema (suggestie)

- `security-selfcheck.yml`: dagelijks, bijv. `30 7 * * *`. Alleen lezen, dus
  veilig om in te plannen.
- `maintenance-cycle.yml`: wekelijks in de nacht, bijv. zondag `0 1 * * 0`.
  Draait standaard op alle hosts tegelijk (35-45 minuten); met
  `batch_size: 1` host voor host, met zes hosts dan 4-5 uur. Plan de AIDE- en
  rkhunter-crons (03:00 en 05:00) niet tegelijk met een lopende ronde, of
  begin vroeg genoeg. Verschillende omgevingen kun je op verschillende nachten
  zetten.
- `status.yml`: kan veilig ingepland worden (alleen lezen).
- `update-containers.yml`, `update-baseline.yml`, `system-updates.yml`,
  `aide-refresh.yml`, `watchdog-reset.yml` en `coolify-redeploy.yml`: liever
  niet inplannen; draai ze bewust, eerst met `dry_run=true` waar dat kan.
- `reboot.yml`: **nooit** inplannen.
- `test-alerts.sh` niet los inplannen (zie `docs/COMMANDS.md`); de
  onderhoudsronde draait het al.

## Lokaal testen

```bash
cd semaphore
cp inventory.example.ini inventory.ini   # vul echte hosts in
ansible-playbook --syntax-check maintenance-cycle.yml
ansible-playbook security-selfcheck.yml --limit server1.example.com
```
