# Inventario rete home-life.hub (192.168.1.0/24)

Catalogo degli host rilevati con `nmap -p 22 --script ssh-hostkey,banner
-sV -O --osscan-limit 192.168.1.0/24`, eseguito dall'utente da
`forge-poc-host-2` il 2026-09-02. Solo catalogazione — **nessun
accesso tentato** su questi host in questa sessione, in attesa di
priorità e credenziali dall'utente. Nessuna credenziale riportata qui,
stessa regola di [accesso_logico.md](accesso_logico.md).

18 host su 256 IP scansionati.

## Rilevanti per FORGE-AI / infrastruttura Dell

| IP | Hostname | Servizio SSH | MAC / vendor | Note |
|---|---|---|---|---|
| `192.168.1.181` | `openmanage-enterprise` | closed | VMware (`00:0c:29:12:f3:3c`) | **Dell OpenManage Enterprise**, VM VMware — piattaforma di management Dell, verosimilmente già a conoscenza del VRTX e di altro hardware Dell sulla rete. Nessuna porta SSH aperta (gestione probabilmente solo via HTTPS). **Priorità alta** per correlare con l'assessment VRTX. |
| `192.168.1.150` | `cmc-35TDGZ1` | open, OpenSSH 7.9 | Dell (`F0:4D:A2:74:48:85`) | Il CMC del VRTX, già documentato in [VRTX-ASSESSMENT.md](VRTX-ASSESSMENT.md) |
| `192.168.1.189` | `apc9A696C` | open, APC AOS cryptlib sshd | APC (`00:C0:B7:9A:69:6C`) | **Confermato dall'utente: è un PDU APC (Power Distribution Unit), non una UPS** — corretto rispetto alla mia ipotesi iniziale. Distribuisce/misura l'alimentazione, non necessariamente con batteria di backup. Resta comunque rilevante per il discorso consumi/alimentazione già trattato nell'assessment VRTX |
| `192.168.1.171` | `forge-poc-host-2` | open, OpenSSH 9.6p1 Ubuntu | — | L'host da cui è partita la scansione stessa — già noto, PoC host di FORGE-AI |
| `192.168.1.135` | `Cisco-SG300` | open, "OpenSSH 5.9p1.RL Allied Telesis" | Cisco (`CC:D8:C1:6E:F0:96`) | **Confermato dall'utente**: è realmente uno switch Cisco SG300. Il banner SSH "Allied Telesis" è quindi solo una stringa di firmware generica/riciclata, non indicativo del vendor reale — nessuna incongruenza sostanziale, solo un banner fuorviante. |
| `192.168.1.106` | `TL-WA850RE` | open, Cisco/3com IPSSHd 6.6.0 | — (`62:32:B1:08:3C:A8` — **stesso MAC di berlin-3eie**, vedi sotto) | TP-Link WiFi extender — nome host e banner SSH incoerenti tra loro (banner dice Cisco/3com), da non fidarsi ciecamente |

## Altri host Linux (dev/test, non ancora correlati a un progetto noto)

| IP | Hostname | Servizio SSH | MAC / vendor | Note |
|---|---|---|---|---|
| `192.168.1.96` | `claude-code-test2` | open, OpenSSH 9.6p1 Ubuntu | VMware (`00:0C:29:79:43:FF`) | VM Ubuntu, nome suggerisce un ambiente di test Claude Code separato da questo — non questa sessione |
| `192.168.1.110` | `berlin-3eie` | open, OpenSSH 9.6p1 Ubuntu | — (`62:32:B1:08:3C:A8`, **stesso MAC di TL-WA850RE `.106`** — indirizzo IP diverso, stesso MAC: sospetto NAT/bridge o errore di lettura ARP, da chiarire) | Il nome combacia con "kickstart-berlin", il progetto futuro di Daniele annotato in memoria (ISO speciale, VM con nested virt + GPU passthrough) — verosimilmente già in lavorazione |
| `192.168.1.100` | (nessuno, solo IP) | open, OpenSSH 10.2p1 Ubuntu | Intel (`00:15:17:F2:DA:09`) | Host Linux senza hostname DNS risolto |
| `192.168.1.133` | (nessuno, solo IP) | open, OpenSSH 9.0 | HP (`40:A8:F0:55:C4:8C`) | **Già identificato in [VRTX-ASSESSMENT.md](VRTX-ASSESSMENT.md)**: workstation HP Z620 dell'utente, non correlata al VRTX |
| `192.168.1.32` | (nessuno, solo IP) | filtered | Xensource (`00:16:3E:45:BD:A4`) | VM/host su hypervisor Xen — porta 22 filtrata, non raggiungibile per probe di servizio |

## Infrastruttura di rete / periferiche (fuori scope FORGE-AI, solo per completezza)

| IP | Hostname | Servizio SSH | Vendor | Tipo |
|---|---|---|---|---|
| `192.168.1.1` | `home-life.hub` | filtered | Zyxel | **Confermato dall'utente**: è il router internet — dà il nome al dominio DNS locale |
| `192.168.1.72` | `DESKTOP-E278L99` | filtered | Hewlett Packard | **PC dell'utente** (Daniele) — stesso MAC già visto nella ARP table del CMC come primo host collegato |
| `192.168.1.91` | (nessuno) | filtered | Amazon Technologies | Verosimilmente un dispositivo Echo/Alexa |
| `192.168.1.95` | `ESP_C22E7F` | closed | Espressif | Dispositivo IoT (ESP32/8266) |
| `192.168.1.99` | `ESP_F94ED3` | closed | Espressif | Dispositivo IoT (ESP32/8266) |
| `192.168.1.146` | `DCS-8515LH` | closed | D-Link | Telecamera IP |
| `192.168.1.170` | `EPSONC3F1DA` | closed | Seiko Epson | Stampante di rete |

## Host noto ma assente dai risultati della scansione

| IP | Identità | Fonte | Nota |
|---|---|---|---|
| `192.168.1.10` | HP ProCurve 2810 (switch) | confermato dall'utente | **Non comparso** tra i 18 host "up" della scansione nmap — non è chiaro se offline al momento della scan, non risponde ai probe usati (ICMP/TCP-22), o un problema di rete diverso. Da riverificare con una scansione dedicata se rilevante. |

## Priorità suggerite (da confermare con l'utente)

1. **`openmanage-enterprise` (192.168.1.181)** — probabilmente ha già
   un inventario/storico del VRTX e di altro hardware Dell della rete;
   accesso solo via HTTPS (porta SSH chiusa), servirebbe l'URL di
   login e credenziali
2. **UPS APC (192.168.1.189)** — collega direttamente al tema
   alimentazione già aperto nell'assessment VRTX
3. **Incongruenza `.106`/`.110`** (stesso MAC, hostname/banner
   incoerenti) — ancora da chiarire, non risolta
4. ~~Switch `.135`~~ — risolto: confermato Cisco SG300, banner SSH
   solo fuorviante

Nessuna azione eseguita oltre alla catalogazione. In attesa di
indicazioni su quali host approfondire e con quali credenziali.
