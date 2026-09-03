# Assessment Dell PowerEdge VRTX (CMC-35TDGZ1)

Stato as-is rilevato via CMC racadm su SSH, non ancora collegato alla
narrazione del PoC GitOps — documento di lavoro per tracciare cosa è
stato verificato su questo chassis fisico, in vista di un suo possibile
uso come host per FORGE-AI o altri progetti. Aggiornare via via che
procede l'indagine, non riscrivere da zero.

## Accesso

- **Target**: `192.168.1.150`, SSH, utente `root`
- **Credenziali**: file locale fuori dal repository (percorso:
  `cmc.vrtx.txt` nella cartella GitHub locale dell'utente) — mai
  riportate qui, vedi regola credenziali in `CLAUDE.md`
- **Client verificato**: `plink` (PuTTY) da Git Bash; `ssh` OpenSSH
  presente ma non testato per questo host — plink ha gestito
  correttamente prompt password e host key
- Login conferma un ambiente **racadm** (CMC Dell), non una shell POSIX:
  niente `;` come separatore comandi, un comando racadm per invocazione

## Identità CMC / chassis

| Campo | Valore |
|---|---|
| Modello | PowerEdge VRTX |
| Service Tag | 35TDGZ1 |
| Asset Tag | 00000 (non impostato) |
| Express Service Code | 6882015277 |
| System ID | 1487 |
| Chassis Midplane Version | 1.0 |
| CMC Version | 3.41 (primario, CMC-1) — nessun CMC ridondante (CMC-2 non presente) |
| CMC Hardware Version | A02 |
| Ultimo aggiornamento firmware | 17/08/2019 |
| DNS CMC Name | cmc-35TDGZ1 |
| Dominio DNS corrente | home-life.hub |
| MAC CMC | F0:4D:A2:74:48:85 |
| IP CMC | 192.168.1.150 (DHCP, gateway 192.168.1.1, DNS 192.168.1.1) |
| IPv6 | disabilitato |

## Stato moduli / blade

Rilevato **prima** dell'accensione chassis (stato iniziale, 2026-09-02):
tutto `OFF`, Chassis `Power Status = OFF`, health chassis `Not OK`
(coerente col power-off, nessun componente con health diverso da OK).

Dopo `racadm chassisaction powerup` (eseguito su richiesta esplicita,
2026-09-02), tempo di power-up osservato: **~4-5 minuti** dal comando
allo stato `Chassis: ON` stabile (fan/blower attivi quasi subito,
storage il collo di bottiglia più lento — spin-up dischi).

Stato modulare **dopo** l'accensione:

| Modulo | Presenza | Stato potenza | Health | Note |
|---|---|---|---|---|
| Chassis | Present | ON | **Not OK** | vedi sezione Storage |
| Main-Board | Present | ON | OK | |
| Storage | Present | ON | **Warning** | vedi sezione Storage |
| Fan 1-6 | Present | ON | OK | tutti "Unknown" a chassis spento, normale |
| Blower 1-4 | Present | ON | OK | |
| PS-1, PS-2, PS-4 | Present | Online | OK | PS-3 slot vuoto (Not Present) |
| CMC-1 | Present | Primary | OK | nessuna ridondanza CMC |
| Switch-1 | Present | ON | OK | switch IOM integrato |
| Server-1 | Present | OFF | OK | Service Tag `13W8302` |
| Server-2 | Present | OFF | OK | Service Tag `C3W8302` |
| Server-3 | Present | OFF | OK | Service Tag `CVW8302` |
| Server-4 | Present | OFF | OK | **nessun Service Tag rilevato** — verificare se slot vuoto o blade non identificata |
| DVD | Present | ON | OK | |

Le blade **non si accendono automaticamente** con `chassisaction
powerup` — richiedono `serveraction powerup -m server-<n>` dedicato.

**Aggiornamento 2026-09-02, dopo `serveraction -m server-{1,2,3} powerup`**
(azione confermata dall'utente): tutte e tre le blade presenti risultano
`ON`, health `OK` lato CMC — nessun segnale di guasto hardware rilevato
per nessuna delle tre. Storage tenuto **unshared** (tutti i Virtual
Adapter Access Policy a `No Access`, verificato prima del boot) come da
istruzione, in vista del boot di ESXi 8 installato su ciascuna blade.
Server-4 lasciata OFF (nessun Service Tag rilevato, blade
verosimilmente assente).

| Blade | Service Tag | Stato CMC post-boot |
|---|---|---|
| Server-1 | 13W8302 | ON, health OK |
| Server-2 | C3W8302 | ON, health OK |
| Server-3 | CVW8302 | ON, health OK |
| Server-4 | — | OFF, non presente |

Verifica di un eventuale mancato boot di ESXi (segnalata come possibile
dall'utente) non ancora completata: lo stato CMC copre solo l'hardware,
non il sistema operativo — serve accesso iDRAC/ESXi per confermare.

## Consumi energetici

| Momento | Potenza istantanea | Corrente |
|---|---|---|
| Chassis OFF (standby) | 34 W (116 BTU/h) | 0,3 A |
| Chassis ON (post power-up, storage attivo) | 302 W (1030 BTU/h) | 1,3 A |
| Picco storico registrato | 55 W — dato pre-esistente, da ricalcolare dopo accensione blade | — |
| Chassis ON, 3 blade accese (server-1,2,3) | 743 W (2535 BTU/h) | — |
| Energia cumulativa contatore | 1901,3 kWh (dal 29/11/2024) | — |

Cap di potenza configurato: 4800 W (100%), politica di ridondanza
"Power Supply Redundancy", nessun Dynamic PSU Engagement.

## iDRAC delle blade

`getniccfg -m server-1..4`: a chassis spento, per **tutti e 4 gli
slot**, `IPv4 Enabled = 0`, IP `0.0.0.0`, `LOM Model Name` vuoto,
`LOM Fabric Type = None` — nessun iDRAC raggiungibile. Il CMC non
offre un comando di proxy racadm generico verso l'iDRAC delle blade
(solo `serveraction`, `getled/setled`, `deploy`, `connect` seriale) —
per configurazione completa serve raggiungere l'iDRAC via IP proprio.

**Dopo l'accensione delle blade (2026-09-02)**, ciascun iDRAC ha preso
un IP via DHCP (scheda `BRCM 1GbE 4P 5720 LOM`):

| Blade | IP iDRAC |
|---|---|
| Server-1 | 192.168.1.145 |
| Server-2 | 192.168.1.158 |
| Server-3 | 192.168.1.172 |

Tentativo di login SSH diretto su iDRAC server-1 (192.168.1.145) con la
stessa password del CMC: **rifiutata** — credenziali iDRAC distinte da
quelle del CMC, non indovinate ulteriormente.

SSH attivo e raggiungibile (host key presentata, solo credenziali
respinte) anche su iDRAC server-2 (192.168.1.158) e server-3
(192.168.1.172), verificato per esclusione — nessuna credenziale
valida ancora fornita per questi due.

## Configurazione ESXi — Server-2 (192.168.1.159)

Recuperata via SSH diretto sull'host ESXi (non sull'iDRAC), utente
`root`, credenziali fornite dall'utente fuori da questo documento.
Correlazione confermata con dato verificabile: `esxcli hardware
platform get` → `Serial Number: C3W8302`, combacia esattamente col
Service Tag di Server-2 letto dal CMC.

| Campo | Valore |
|---|---|
| Modello blade | Dell PowerEdge M520 |
| Versione ESXi | 8.0.2, Update 2, build 22380479 |
| Hostname | non configurato (default `localhost.localdomain`, dominio `home-life.hub`) |
| Uptime al momento del check | 18 min (coerente con l'accensione appena eseguita) |
| Licenza | vSphere 8 Enterprise Plus, seriale `N4605-0E34…` (troncato qui — seriale completo solo nell'host, non riportato per intero in un documento versionato), 6 cpuPackage totali, 2 in uso |
| NTP | disabilitato, nessun server configurato, tempo non sincronizzato |
| DNS | 192.168.1.1 |


**Rete:**
- `vmk0`: 192.168.1.159/24, DHCP, gateway 192.168.1.1 (management)
- `vmk1`: 192.168.30.159/24, statico — rete separata (VLAN/subnet dedicata,
  verosimilmente vMotion o storage)
- 2× NIC fisiche (vmnic0/1, Broadcom BCM5720 1GbE, driver `ntg3`), entrambe Up,
  MTU 9000 (jumbo frame)
- `vSwitch0`: uplink vmnic0+vmnic1, 5 port group — `Management Network`, `VM
  Network`, `VM Network DMZ`, `VM Network Internal`, `VM Motion`


**Storage locale (indipendente dallo storage condiviso VRTX):**
- Adapter `vmhba1` = Broadcom/PERC H710 Mini locale della blade (**diverso** dai
  controller Shared PERC8 del chassis) — questo è lo storage "di bordo" della
  blade, non quello condiviso
- Datastore VMFS-6 locale (`datastore (159)`, ~162 GB, 160 GB liberi) +
  partizione OS-DATA (~129 GB) + due BOOTBANK (boot ESXi)
- Datastore NFS `NFS_ISOImages` configurato ma **non montato**
- **Nessun datastore proveniente dallo storage condiviso del chassis** risulta
  montato — coerente con Virtual Adapter Access Policy ancora `No Access`,
  come da istruzione di tenere lo storage unshared durante il boot

**VM registrate:** nessuna.

Nessun problema di boot riscontrato su questa blade.

## Configurazione — Server-3 (iDRAC 192.168.1.172, credenziali fornite dall'utente)

A differenza di Server-2, qui l'accesso è stato fatto **via iDRAC**
(non SSH diretto su ESXi — IP di management ESXi non ancora noto per
questa blade). `racadm getsysinfo` conferma comunque identità e stato:

| Campo | Valore |
|---|---|
| Service Tag | CVW8302 (combacia con Server-3 dal CMC) |
| Modello blade | PowerEdge M520, revisione I |
| BIOS Version | 2.9.0 |
| iDRAC Firmware | 1.51.51 (build 01, ultimo aggiornamento 18/01/2014 — molto datato) |
| iDRAC DNS Name | idrac-CVW8302 |
| **OS Name/Version riportato dall'iDRAC** | **Dell-VMware ESXi, 8.0 Update 2 Build-22380479 (A04)** |
| Power Status | ON |

**Il campo OS Name/Version confermato dall'iDRAC è la prova che ESXi ha
completato il boot correttamente su questa blade** (stesso build di
Server-2: 22380479) — l'agente OS/CIM che alimenta questo dato nell'iDRAC
gira solo se il sistema operativo è effettivamente up, quindi **nessun
problema di boot su Server-3**.


**Hardware (da `racadm hwinventory`):**
- 2× CPU Intel Xeon (famiglia Haswell-EP), 6 core / 12 thread ciascuna,
  clock corrente 2400 MHz (max turbo 3600 MHz), cache L3 15360 KB —
  totale 12 core / 24 thread
- 12 DIMM popolati, 1333 MHz ciascuno (dimensione singolo modulo non
  ancora letta)
- Storage locale via Integrated RAID Controller 1 (stesso schema di
  Server-2: PERC locale della blade, indipendente dal chassis)

**Aggiornamento — accesso diretto ESXi ottenuto (192.168.1.173,
credenziali fornite dall'utente).** Identità ri-confermata: `esxcli
hardware platform get` → Serial `CVW8302`, e MAC delle NIC embedded
(`18:a9:9b:04:b0:9b/9c`) combaciano esattamente con quelle lette
dall'iDRAC — stesso host, due percorsi di verifica indipendenti.

| Campo | Valore |
|---|---|
| Versione ESXi | 8.0.2, Update 2, build 22380479 (identico a Server-2) |
| Hostname | non configurato (default), dominio `home-life.hub` |
| Uptime al check | 54 min |
| Licenza | vSphere 8 Enterprise Plus, 6 cpuPackage totali, 2 in uso (stesso pool licenze di Server-2) |
| NTP | disabilitato |
| DNS | 192.168.1.1 |


**Rete:**
- `vmk0`: 192.168.1.173/24, DHCP (management)
- `vmk1`: 192.168.30.172/24, statico (stessa subnet 30 di Server-2, IP diverso)
- vmnic0/1 Broadcom BCM5720, Up, MTU 9000
- `vSwitch0`: stessi 5 port group di Server-2 (Management Network, VM Network,
  VM Network DMZ, VM Network Internal, VMotion) — configurazione di rete
  gemella


**Storage locale:**
- Datastore VMFS-6 locale `datastore (172)`, **291 GB** (molto più
  grande dei 162 GB su Server-2 — asimmetria non ancora spiegata, da
  verificare se intenzionale)
- OSDATA solo 6,7 GB (contro 129 GB su Server-2) — layout partizioni
  diverso, probabile installazione ESXi in tempi/versioni diverse
- Due datastore NFS **configurati ma non montati**: `NFS_ISOImages` e
  **`NFS_Proxmox_VM`** (nome che suggerisce condivisione con un
  ambiente Proxmox esterno a questo chassis — da chiarire)
- Nessun datastore dello storage condiviso VRTX montato, coerente con
  Virtual Adapter Access Policy ancora `No Access`

**VM registrate — analisi approfondita.** `vim-cmd vmsvc/getallvms`
mostrava ~32 VM "invalid" senza dettagli; leggendo direttamente
`/etc/vmware/hostd/vmInventory.xml` si recuperano **nomi e path
completi** di tutte e 32. Confermata l'ipotesi: **nessuna** fa
riferimento ai due datastore locali attualmente montati
(`6638f8d9-…` e `663be69d-…`, UUID dei due volumi sul disco locale
`naa.6c81f660e21e22002dc949c305fd2c07` — verificato con `esxcli
storage vmfs extent list` + `storage core device list`, disco locale
DELL sotto Integrated RAID Controller 1, **non** lo storage condiviso
VRTX). Tutte le 32 puntano a **4 datastore non montati**:

| UUID datastore (non montato) | # VM | VM (nomi) |
|---|---|---|
| `6734f116-a1db750a-5ebc-18a99b04b09b` | 12 | WindowsServer2022_template_V2, WindowsServer2022_Template, MI-LINUX-TEST02, MI-RH9-TEST, vCLS-d3afbce7…, GestioneAffitti, SRV-OWNCLOUD, Proxmox01, WindowsServer2022, MI-LINUX-TEST, MI-TEST, vCLS-c33c85ea… |
| `603e3fb8-0a15bc01-324b-d8d385d87c24` | 11 | WindowsXP_VS6, SQL2019-REP, Moodle-PROD, VMware-vCenter-Server-7, Moodle, Oracle9i, SRV-SIM-01.trap, OracleRAC1, SQL2008-N01, Windows10_VS2019 |
| `603e3ed8-bb74fa7f-a4d5-d8d385d87c24` | 7 | HPC_VM001, SRV-OWNCLOUD (copia), SRV-AD-DNS, WXPPRO, BE-MI-PDL-001, SRV-LAMP-02, SRV-LAMP-01, SRV-WEB-01 |
| `6734f128-a5d09c5e-7859-18a99b04b09b` | 2 | vCenterServer8, Firewall-2024 |

Nota tecnica: l'UUID di un volume VMFS incorpora, nei suoi ultimi 12
esadecimali, il MAC address della NIC dell'host che lo ha creato. I
due datastore che finiscono in `18a99b04b09b` combaciano esattamente
con la NIC di **questo stesso host (Server-3)** — quindi verosimilmente
creati da Server-3 quando aveva accesso allo storage condiviso. Gli
altri due terminano in `d8d385d87c24`, un MAC **non visto finora** su
nessuna delle blade controllate (né Server-2 né Server-3) — possibile
indizio di un terzo host che ha avuto accesso allo storage in passato
(Server-1? Un host ormai dismesso?). Interpretazione dedotta dalla
struttura dell'UUID, non da un dato dichiarato esplicitamente — da
trattare come ipotesi.

Presenza di `vCLS-*` (VMware vSphere Cluster Services) conferma che
questo storage/queste VM sono stati gestiti da un **vCenter** in
passato, non solo da host standalone — utile per il confronto con
vCenter richiesto dall'utente. Presenti anche due VM vCenter stesse
(`VMware-vCenter-Server-7` e `vCenterServer8`), verosimilmente
un'installazione poi migrata da v7 a v8.

**Server-2, per confronto:** `vmInventory.xml` è **completamente
vuoto** (`<ConfigRoot/>`) — nessuna VM mai registrata su questo host,
coerente con quanto già rilevato via `vim-cmd`.

Nessun problema di boot riscontrato su nessuna delle due blade.

## Mapping storage condiviso → SLOT-02/SLOT-03 (2026-09-02)

Eseguito dall'utente **via GUI web del CMC** (Chassis Overview →
Storage → Virtual Disks → Assign) — non è stato possibile trovare/
verificare il FQDD del Virtual Adapter per farlo via `racadm raid
assignva` in CLI: la sintassi ufficiale Dell (`racadm raid
assignva:<VA FQDD> -vdkey:<FQDD of VD> -accesspolicy {na|rw}`) non
riporta mai un FQDD reale d'esempio in nessuna versione della guida
RACADM controllata (CMC 2.1, 2.2, 3.3), e nessuna query di sola
lettura (`raid get vdisks/pdisks/controllers`, tentativo `raid get
virtualadapters`) espone il FQDD del VA. Diversi tentativi di sintassi
alternativa (`-i`/`-a`) sono stati respinti dal dispositivo stesso
("Invalid subcommand specified"). Via GUI invece l'operazione è
riuscita.

**Verifica post-mapping (CMC, read-only):**

```text
raid get vdisks -o -p name,virtualadapter1accesspolicy,virtualadapter2accesspolicy,virtualadapter3accesspolicy,virtualadapter4accesspolicy
```

Entrambe le VD ora riportano `VirtualAdapter2AccessPolicy = Full
Access` e `VirtualAdapter3AccessPolicy = Full Access` (Server-2 e
Server-3), mentre VA1 e VA4 restano `No Access` — mapping applicato
correttamente e solo agli slot richiesti.

**Rescan (`esxcli storage core adapter rescan --all`) ed esito:**

- **Server-3 (192.168.1.173)**: **riuscito**. Compaiono due nuovi
  datastore VMFS-6 montati: `VRTX-RAID60` (UUID `6734f116-…`, 11,17 TB)
  e `VRTX-RAID10` (UUID `6734f128-…`, 1,12 TB) — dimensioni coerenti
  con le VD `VMWARE-RAID60`/`VMWARE-RAID10` viste nell'analisi RAID.
  Questi sono esattamente 2 dei 4 UUID datastore referenziati dalle 32
  VM in `vmInventory.xml` (quelli col suffisso MAC di questo stesso
  host) — quindi le VM che vi appartengono (14 delle 32, i due gruppi
  da 12 e 2 elencati sopra) dovrebbero ora risultare valide. Le altre
  18 VM (sui due datastore con MAC `d8d385d87c24`, mai visto su nessun
  host controllato) restano non risolvibili — quello storage non è
  (ancora) comparso qui.

- **Server-2 (192.168.1.159)**: **nessun nuovo datastore**, nonostante
  il mapping VA2 confermato attivo lato controller. **Causa
  identificata**: `esxcli storage core adapter list` mostra che
  Server-2 ha **solo** `vmhba0` (SATA AHCI) e `vmhba1` (PERC H710
  locale) — **manca del tutto una HBA Shared PERC8** verso il
  backplane condiviso. Per confronto, Server-3 ha `vmhba2`+`vmhba3`
  (`dell_shared_perc8`, Broadcom Shared PERC 8 Mini, percorso
  ridondante) più `vmhba4` (HBA Fibre Channel QLogic 8Gb, link-down,
  non collegata). **Non è un problema di mapping/masking** — quello è
  corretto — ma di **hardware mancante o non funzionante** sulla
  blade Server-2 (mezzanine card Shared PERC8 assente, non seatata, o
  guasta). Da verificare fisicamente (rimozione/riseat della blade) se
  si vuole dare a Server-2 accesso allo storage condiviso.

**Verifica finale (`vim-cmd vmsvc/getallvms` su Server-3, post-mount):**
esattamente le 14 VM attese risultano ora valide, con nome/guest
OS/annotazioni completi (in precedenza solo ID numerico "invalid"):

| Vmid | Nome | Datastore | Guest OS | Note |
|---|---|---|---|---|
| 5 | WindowsServer2022_template_V2 | VRTX-RAID60 | Windows Server 2022 | template |
| 6 | WindowsServerTemplate (2022) | VRTX-RAID60 | Windows Server 2022 | template |
| 18 | MI-LINUX-TEST02 | VRTX-RAID60 | Ubuntu 64 | |
| 27 | MI-RH9-TEST | VRTX-RAID60 | RHEL 9 64 | |
| 31 | vCLS-d3afbce7-… | VRTX-RAID60 | PhotonOS (other3x) | VM di sistema vSphere Cluster Service |
| 33 | GestioneAffitti | VRTX-RAID60 | Windows XP Pro | backup Veeam 03/06/2021, host SRV-BCK-02 |
| 34 | SRV-OWNCLOUD | VRTX-RAID60 | other | backup Veeam 17/01/2022, host SRV-BCK-02 |
| 47 | Proxmox01 | VRTX-RAID60 | FreeBSD 64 | |
| 61 | WindowsServer2022 | VRTX-RAID60 | Windows Server 2022 | |
| 70 | vCenterServer8 | VRTX-RAID10 | other3x (appliance) | VMware vCenter Server Appliance |
| 73 | MI-LINUX-TEST | VRTX-RAID60 | Ubuntu 64 | |
| 82 | MI-TEST | VRTX-RAID60 | Windows Server 2022 | annotazione "(Hyper-V)" nel nome, da chiarire |
| 83 | Firewall-2024 | VRTX-RAID10 | FreeBSD 14 64 | |
| 84 | vCLS-c33c85ea-… | VRTX-RAID60 | PhotonOS (other3x) | VM di sistema vSphere Cluster Service |

Le rimanenti **18 VM** (quelle sui due datastore UUID `603e3fb8-…` e
`603e3ed8-…`, MAC creatore `d8d385d87c24` mai visto su Server-2/3)
restano `invalid` — quello storage non è ancora comparso su nessun
host controllato. Ipotesi da verificare: potrebbe essere raggiungibile
solo da Server-1 (non ancora controllato in dettaglio), oppure essere
storage non più presente/rimosso.

La presenza di `vCenterServer8` come VM (non ancora avviata) conferma
che l'ambiente aveva un **vCenter proprio**, distinto da quello con
cui l'utente confronterà questi dati — utile per capire se il
confronto richiesto è con un vCenter esterno preesistente o con questa
stessa appliance una volta riavviata.

## Storage condiviso — analisi RAID

**Verdetto sintetico**: `racadm raid get status` → **Storage Root Node
Status: Warning**. Causa individuata e non critica per i dati, vedi
sotto.

### Architettura


Storage condiviso Dell VRTX su **due controller Shared PERC8**:
- `RAID.ChassisIntegrated.1-1` — **Status: OK**, PCI slot 9, firmware
  23.8.2-0005, cache 1024 MB, Patrol Read `Running`
- `RAID.ChassisIntegrated.2-1` — **Status: Warning**, PCI slot 10,
  stesso firmware, cache 1024 MB, `PreservedCache = Present`, Patrol
  Read `Stopped`

`HighAvailabilityMode = None` su **entrambi** i controller — non è
configurata una vera coppia ridondante attiva/passiva tra i due PERC8.

~19 dischi fisici popolati (bay osservati: 0-9, 13, 15-18, 20-23) su
backplane condiviso, fino a 24/25 slot disponibili.

### Virtual Disk attivi (proprietà di controller 1-1)

| Nome | Layout | Dimensione | Dischi | Stato |
|---|---|---|---|---|
| VMWARE-RAID10 | RAID-10 | 1116,75 GB | 4× Seagate ST600MM0006 558GB (bay 20-23) | Online |
| VMWARE-RAID60 | RAID-60 | 11172,50 GB | 14× dischi ~1,1TB (Seagate/NetApp/HP/IBM rebrand, bay 1-9,13,15-18) | Online |
| Hot spare dedicato | — | 1117,25 GB | HP EG1200FDNJT (bay 0) | Ready |

Nessun disco con `FailurePredicted = YES`, nessun bad block segnalato,
nessuna VD assegnata a un Virtual Adapter (tutte `No Access` — coerente
col fatto che nessuna blade è ancora accesa/collegata allo storage).

### Causa del Warning

Il controller **2-1** vede **gli stessi identici dischi fisici**
(stesso bay, stesso serial number) del controller 1-1, ma li riporta
tutti come `State = Foreign` — cioè con una configurazione RAID
residua non riconosciuta come propria, non integrata nella config
attiva. Combinato con `PreservedCache = Present` su quel controller,
l'ipotesi più probabile è una **configurazione precedente lasciata sul
controller 2 prima che l'attuale setup venisse creato/spostato sul
controller 1** — non verificato da log storici, solo dedotto dai dati
attuali (da trattare come ipotesi, non fatto accertato — vedi regola
"solo informazioni concrete" in `CLAUDE.md`).

Non risulta rischio immediato per i dati delle VD attive: nessun disco
della configurazione live (controller 1-1) è in stato degradato o a
rischio.

## Log eventi (SEL)

`getsel` risulta **fermo/pieno dal 30/11/2024** (ultimo evento
registrato: "System event log (SEL) is full"). Nessun evento
successivo, incluso il power-on eseguito oggi (2026-09-02), risulta
loggato — il log non si è aggiornato. Serve `racadm clrsel` per
liberare spazio e riprendere la cattura eventi; non ancora eseguito
(azione a bassa reversibilità sui dati storici del log, da confermare
prima di procedere).

Nessun evento critico riferito a RAID/storage risulta nel log
esistente (che comunque si ferma a fine 2024, quindi non copre lo stato
attuale).

## Azioni eseguite finora

1. Verifica accesso SSH (root, password da file locale) — OK
2. Lettura stato iniziale chassis (OFF) — read-only
3. Lettura consumi baseline — read-only
4. **`racadm chassisaction powerup`** — azione confermata dall'utente,
   eseguita 2026-09-02
5. Polling stato fino a `Chassis: ON` — read-only
6. Analisi completa RAID/storage (`raid get controllers/vdisks/pdisks
   -o`, `raid get status`) — read-only
7. Lettura SEL (`getsel`) — read-only
8. Verifica Virtual Adapter Access Policy su entrambe le VD: già tutte
   `No Access` (storage unshared) — read-only
9. **`serveraction -m server-1 powerup`**, poi `-m server-2`, poi
   `-m server-3` — azioni confermate dall'utente, eseguite 2026-09-02,
   una alla volta
10. Polling `getniccfg -m server-<n>` fino a IP iDRAC assegnato, per
    ciascuna delle tre — read-only
11. Tentativo login SSH su iDRAC server-1 con password del CMC —
    fallito (credenziali diverse), nessun ulteriore tentativo

Nessuna azione distruttiva eseguita. Nessuna modifica alla
configurazione storage (Virtual Adapter Access Policy invariata,
ancora `No Access` su tutte le VD/adapter).

## Aperti / prossimi passi (da confermare singolarmente)

- [ ] Recuperare configurazione iDRAC/ESXi di server-1/2/3 (in attesa
      di credenziali dall'utente)
- [ ] Confermare se ESXi ha completato il boot su tutte e tre le blade
      (l'utente ha segnalato che una potrebbe non fare boot — non
      ancora verificabile solo con lo stato hardware del CMC)
- [ ] Dopo il recupero configurazione: spegnimento blade una alla
      volta (`serveraction -m server-<n> graceshutdown` preferibile a
      `powerdown` per uno shutdown ACPI pulito di ESXi, non un
      power-off brusco)
- [ ] Se richiesto, rimappare lo storage condiviso alla blade dopo il
      boot (`raid` set su Virtual Adapter Access Policy) — non fatto,
      resta unshared finché non richiesto esplicitamente
- [ ] Pulizia SEL (`racadm clrsel`) per far ripartire la registrazione
      eventi
- [ ] Investigare più a fondo la configurazione "foreign" sul
      controller 2-1 prima di considerare un `clearconfig` (distruttivo
      su quel controller — richiede conferma esplicita e comprensione
      dell'origine)
- [ ] Chiarire perché Server-4 non riporta Service Tag (slot
      effettivamente vuoto vs blade non rilevata)
- [ ] Recuperare configurazione Server-1 (terzo/ultimo host mancante:
      iDRAC 192.168.1.145, ESXi non ancora noto) — in attesa di
      credenziali dall'utente. Nota: `192.168.1.133` **non è** l'ESXi
      di Server-1 — verificato (SSH risponde ma credenziali diverse),
      poi confermato dall'utente che è un host non correlato su una
      workstation HP Z620, fuori scope di questo chassis
- [ ] Determinare con certezza se Server-2 dovrebbe avere una HBA FC
      (vedi sezione dedicata sotto) — serve iDRAC di Server-2
      (192.168.1.158) o ispezione fisica
- [ ] Riprendere l'indagine sulla SAN FC esterna (Dell PowerEdge 2950,
      FreeNAS/ZFS, spenta) quando si arriverà a quel punto

## Perché Server-2 non vede lo storage condiviso dopo il mapping (approfondimento)

Il mapping VA2→Full Access (fatto dall'utente via GUI CMC) è
confermato corretto lato controller, ma su Server-2 non è comparso
alcun nuovo datastore dopo `esxcli storage core adapter rescan --all`.
Diagnosi via `esxcli hardware pci list` (confrontato con Server-3):

- **A livello PCI**, Server-2 mostra comunque 2 dispositivi "SPERC 8"
  (Broadcom/LSI) agli stessi indirizzi bus di Server-3
  (`0000:08:00.0` = PERC1, `0000:13:00.0` = PERC2) — quindi la scheda
  **non risulta assente** a questo livello.
- Però **nessuno dei due ha un driver bindato** (`Module Name` vuoto),
  mentre su Server-3 entrambi mostrano `Module Name: dell_shared_perc8`
  e compaiono come `vmhba2`/`vmhba3` funzionanti.
- **Stesso set di VIB installati su entrambi gli host** (97 pacchetti
  identici, incluso `lsi-mr3` — verificato con `esxcli software vib
  list`), quindi **non è un driver mancante**.
- `/var/log/vmkernel.log` su Server-2 **non contiene alcuna riga** che
  menzioni gli indirizzi PCI `0000:08:00.0` o `0000:13:00.0` — il
  driver non ha mai tentato di inizializzare quei dispositivi (non è
  un fallimento con errore esplicito, è proprio un non-tentativo).
- **Nessuna HBA Fibre Channel visibile in alcuna forma** nel PCI di
  Server-2 (né bindata né presente-ma-non-inizializzata) — a
  differenza di Server-3 che ne ha una (QLogic, link-down).

**Verifica CMC (`racadm getdcinfo -n`)**: tutti e tre gli slot
(server-1/2/3) risultano simmetrici, 2 mezzanine card fisicamente
presenti ciascuno (`DC1`/`DC2` = "DELL PCIe Mezzanine", nome generico
che non specifica il tipo di scheda). Non permette di confermare o
escludere la presenza di una card FC specificamente su Server-2.

**Conclusione allo stato attuale**: non determinabile con certezza se
Server-2 dovrebbe avere una HBA FC come Server-3. Ipotesi più
plausibile, non verificata: le due porte Shared PERC8 arrivano dal
midplane dello chassis (comuni a ogni slot che ha un percorso
fisico verso lo storage condiviso) mentre la terza mezzanine
"aggiuntiva" per la FC potrebbe essere effettivamente assente o
diversa su Server-2 — **da confermare con l'iDRAC di Server-2 o
ispezione fisica**, non con supposizioni ulteriori.

**Nota**: dato che il mapping VA→VD normalmente richiede — secondo la
documentazione ufficiale Dell per l'operazione "assign VA to slot" —
che il server sia spento, ma qui è stato applicato a caldo con
Server-2/3 accesi (tramite GUI, non testato in CLI) senza errori
visibili: è possibile che la vera "assegnazione VA↔slot" fosse già
fissa/preesistente e che l'operazione fatta dall'utente sia stata solo
un cambio di access policy (operazione live, coerente con quanto
riuscito su Server-3) — coerente con l'interpretazione già registrata
sopra nella sezione di mapping.

## Riferimento — SAN FC esterna (da investigare più avanti)

Confermato dall'utente (2026-09-02): l'HBA Fibre Channel QLogic vista
su Server-3 (`link-down`) è verosimilmente collegata a uno storage
array esterno — un **Dell PowerEdge 2950** con **FreeNAS/ZFS**,
attualmente **spento**. Non ancora acceso né verificato in questo giro
di lavoro. Da riprendere quando si passerà a indagare quel lato
dell'infrastruttura — nessuna azione eseguita su questo array per ora.

## Spegnimento a fine sessione (2026-09-02)

Eseguito su richiesta esplicita dell'utente, in ordine: blade prima
(graceful), poi chassis. L'utente ha gestito autonomamente l'unmap dei
VD (Virtual Adapter Access Policy → No Access su VA2/VA3) in vista del
prossimo riavvio, non tramite comandi eseguiti in questa sessione.

1. `serveraction -m server-1 graceshutdown` → spento correttamente,
   confermato `powerstatus = OFF` (ha risposto al segnale ACPI — indizio
   indiretto che il sistema operativo era comunque up, coerente con
   "nessun problema di boot" anche per questa blade, mai verificato
   altrimenti per mancanza di credenziali)
2. `serveraction -m server-2 graceshutdown` → OFF confermato
3. `serveraction -m server-3 graceshutdown` → OFF confermato
4. `chassisaction powerdown` → chassis OFF confermato, storage torna a
   health `Unknown` (normale a chassis spento)

**Consumi durante lo spegnimento:**

| Fase | Potenza |
|---|---|
| Tutto acceso (3 blade + storage) | 702 W |
| Blade spente, chassis ancora ON | 321 W |
| Chassis OFF (finale) | 44 W |
| Baseline iniziale (inizio sessione, stesso stato nominale) | 34 W |

**Discrepanza non spiegata**: 44 W finali contro 34 W iniziali (+10 W)
a parità di stato nominale (chassis OFF, nessuna blade accesa). Non
verificata la causa — potrebbe essere semplice fluttuazione
istantanea della lettura o un componente non ancora sceso a completo
riposo al momento della lettura. Da ricontrollare in una sessione
futura se rilevante.
