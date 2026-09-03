# Accesso logico — Dell PowerEdge VRTX (35TDGZ1)

Inventario degli endpoint e degli account usati nella sessione di
assessment del 2026-09-02 (vedi [VRTX-ASSESSMENT.md](VRTX-ASSESSMENT.md)
per il dettaglio delle verifiche). Solo IP/URL/utenze — **nessuna
password è riportata qui**, per la stessa regola già in vigore per
commit/logbook/Artifact in questo repository (vedi `CLAUDE.md`): le
credenziali vivono solo in file locali fuori dal repo, o le fornisce
l'utente al momento in chat.

## CMC (Chassis Management Controller)

| Campo | Valore |
|---|---|
| IP | `192.168.1.150` |
| Hostname DNS | `cmc-35TDGZ1` |
| Accesso CLI | SSH (porta 22), utente `root` |
| Accesso Web | `https://192.168.1.150` |
| Client CLI verificato | `plink` (PuTTY) — gestisce correttamente prompt password e host key su questo dispositivo |
| Credenziali | file locale fuori dal repo (`cmc.vrtx.txt` nella cartella GitHub locale dell'utente) |
| Note | `ssh` OpenSSH nativo presente ma non testato su questo host in questa sessione |

## iDRAC per blade

| Blade | Service Tag | IP iDRAC | Accesso | Credenziali |
|---|---|---|---|---|
| Server-1 | `13W8302` | `192.168.1.145` | SSH, `root` | **non ottenute** — tentata la password del CMC, rifiutata; non indovinata oltre |
| Server-2 | `C3W8302` | `192.168.1.158` | SSH, `root` | **non ottenute** — SSH raggiungibile (host key presentata), nessuna credenziale valida fornita finora |
| Server-3 | `CVW8302` | `192.168.1.172` | SSH, `root` | fornite dall'utente in chat, funzionanti |

## ESXi per blade (accesso diretto, non tramite iDRAC)

| Blade | IP management (vmk0) | Accesso | Credenziali | Verificato tramite |
|---|---|---|---|---|
| Server-1 | non ancora noto | — | — | non ancora identificato/verificato |
| Server-2 | `192.168.1.159` | SSH, `root` | fornite dall'utente in chat, funzionanti | `esxcli hardware platform get` → Serial `C3W8302` combacia |
| Server-3 | `192.168.1.173` | SSH, `root` | fornite dall'utente in chat, funzionanti (stessa password usata anche per l'iDRAC di Server-3) | `esxcli hardware platform get` → Serial `CVW8302` combacia, MAC NIC combaciano con quelle lette dall'iDRAC |

## Rete secondaria osservata sulle blade

- `vmk1` su subnet separata `192.168.30.0/24` (Server-2: `.159`,
  Server-3: `.172`) — statica, verosimilmente vMotion/storage. Nessun
  accesso diretto tentato su questa subnet.

## Host verificati e scartati (fuori scope)

| IP | Esito | Nota |
|---|---|---|
| `192.168.1.156` | non raggiungibile (ping/TCP falliti) | IP inizialmente indicato per errore dall'utente, poi corretto in `.159` |
| `192.168.1.133` | SSH attivo ma credenziali diverse, poi confermato dall'utente | **non è** una blade del VRTX — host distinto su workstation HP Z620 |

## Riferimenti futuri (non ancora acceduti in questa sessione)

| Sistema | IP | Note |
|---|---|---|
| SAN FC esterna | non ancora noto | Dell PowerEdge 2950, FreeNAS/ZFS, attualmente spento — collegato via Fibre Channel all'HBA QLogic di Server-3 (`link-down`). Da investigare in una sessione futura. |

## Strumenti/pattern di accesso verificati in questa sessione

- Login SSH interattivo con password su dispositivi Dell (CMC/iDRAC) via
  `plink -ssh -pw "<password>" root@<ip> "<comando>"`, con `echo y |` o
  `printf 'y\n' |` per accettare l'host key alla prima connessione.
  Preferire `plink -pwfile <file>`: a differenza di `-pw`, non espone la
  password nella command line del processo
- Il CMC espone una shell `racadm` (non POSIX): un comando per
  invocazione, nessun `;` come separatore
- Le iDRAC delle blade **non sono raggiungibili in rete finché lo chassis
  è spento** — serve prima `chassisaction powerup` (chassis) e poi
  `serveraction -m server-<n> powerup` (blade specifica)
