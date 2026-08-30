# 00 — Preparazione accesso e ricognizione host ESXi

Nota sui timestamp: questa voce è stata ricostruita a posteriori (su
richiesta esplicita del coordinatore) a partire dalla cronologia reale dei
comandi eseguiti in questa sessione. Non è stato lanciato `date` prima di
ogni singolo passo, quindi non è disponibile un timestamp HH:MM preciso per
ciascuna sotto-azione di questa prima voce: tutte le azioni descritte qui
sotto sono avvenute in sequenza, in un'unica sessione continua, terminata
attorno alle 2026-08-28 13:28 UTC (primo timestamp effettivamente
catturato, vedi voce 01). Da qui in avanti ogni voce riporta un timestamp
reale.

## 2026-08-28 (ora esatta non catturata) — Lettura assegnamento

**Contesto**: avvio sessione, nessun contesto precedente. Il messaggio del
coordinatore rimanda per intero a `handoff_setup_esxi.md` nella root del
repository come fonte di verità.

**Comando/i**:

    Read C:\Users\danie\Documents\GitHub\FORGE-AI\handoff_setup_esxi.md

**Osservato**: file letto per intero (466 righe). Contiene: obiettivo
(portare il PoC a un'esecuzione e2e su una VM Ubuntu Server 24.04 con
virtualizzazione annidata creata da zero su ESXi 8.0.2), le due
impostazioni obbligatorie sulla VM (hardware-assisted virtualization
esposta al guest; riserva completa della memoria), la specifica VM (8
vCPU, 32GB RAM, disco sistema ~60GB su "datastore NVMe piccolo", disco
dati 300-500GB thin da un "pool da ~5TB"), il layout storage a due volumi
con mount `/srv`, i quattro bug già corretti nel branch (commit c8ed22e,
427a1f5, bc7a90d, e un quarto — group membership kvm/libvirt via reboot,
non documentato con hash perché non è un fix di codice ma una procedura),
le regole di ingaggio (script con `set -Eeuo pipefail`, verifica sintassi
contro documentazione ufficiale, `make validate && make lint` prima di
ogni push, nessun segreto committato, niente force-push), il piano di
lavoro Fase 0 → Fase 12, il formato del logbook, e la lista di cosa non
fare (niente `make destroy`/`destroy-all`, niente snap docker, nessun
tocco ad altre VM/datastore/config host oltre il necessario).

**Stato**: fatto.

## 2026-08-28 (ora esatta non catturata) — Verifica stato repository

**Contesto**: confermare che il branch e i commit attesi dal piano fossero
presenti prima di procedere, come richiesto dal piano stesso ("verifica
prima di andare oltre").

**Comando/i**:

    git log --oneline -6 && echo --- && git status && echo --- && git branch --show-current

**Osservato**:

    9b414c6 docs: add the handoff for ESXi 8 validation
    953fb18 docs: add the handoff for the SSH validation session
    427a1f5 fix: resolve ansible-playbook through the venv, not bare PATH
    c8ed22e fix: install what libvirt-python needs to compile
    bc7a90d fix: check the disk where storage is actually configured, not /srv
    cdff682 security: suppress the samba root-user finding, with its reason
    ---
    On branch claude/gitops-infrastructure-poc-9losz4
    Your branch is up to date with 'origin/claude/gitops-infrastructure-poc-9losz4'.

    nothing to commit, working tree clean
    ---
    claude/gitops-infrastructure-poc-9losz4

**Osservazione**: i tre commit attesi (c8ed22e, 427a1f5, bc7a90d) sono
tutti presenti nella history. Working tree pulito, nessun `git pull`
necessario a questo punto (branch già aggiornato).

**Stato**: fatto.

## 2026-08-28 (ora esatta non catturata) — Verifica credenziali e strumenti disponibili

**Contesto**: verificare, prima di usarli, che il file password esista
localmente e che gli strumenti SSH indicati dal coordinatore (plink,
ssh/ssh-keygen) siano disponibili su questa macchina Windows.

**Comando/i**:

    test -f "/c/Users/danie/Documents/Claude/esxi.txt.txt" && echo "password file exists" && wc -c "/c/Users/danie/Documents/Claude/esxi.txt.txt"
    ping -n 2 192.168.1.133
    ls "/c/Program Files/PuTTY/"; which ssh; which ssh-keygen
    cat "/c/Users/danie/Documents/GitHub/FORGE-AI/.gitignore" | head -50

**Osservato**:

- File password presente, 13 byte (una riga, nessun newline finale —
  coerente con quanto atteso). Il contenuto NON è stato stampato in
  nessun output di comando né qui né altrove: letto solo internamente
  dagli script per costruire comandi non interattivi (vedi sotto).
- Ping a 192.168.1.133: 2/2 pacchetti ricevuti, RTT <1ms — host
  raggiungibile sulla LAN locale.
- `/c/Program Files/PuTTY/` contiene `plink.exe`, `puttygen.exe`,
  `pscp.exe`, `psftp.exe`, `pageant.exe`, `putty.exe`.
- `/usr/bin/ssh` e `/usr/bin/ssh-keygen` presenti (OpenSSH via Git Bash).
- `.gitignore` copre già `config/poc.yml` (con eccezione per
  `config/poc.example.yml`), `.env` e varianti, chiavi private
  (`*.pem`, `*.key`, `id_rsa*`, `id_ecdsa*`, `id_ed25519*` con eccezione
  per `*.pub`), `secrets/`, `.secrets/`, materiale vault Ansible. Nessun
  file nuovo necessario per le credenziali di questa sessione: la
  password ESXi non è mai stata scritta su disco in un file del
  repository, solo letta a runtime dal file esterno indicato dal
  coordinatore (fuori dal repository, in
  `C:\Users\danie\Documents\Claude\esxi.txt.txt`).

**Stato**: fatto.

## 2026-08-28 (ora esatta non catturata) — Generazione coppia di chiavi SSH dedicata (ed25519, poi sostituita)

**Contesto**: seguendo il consiglio del coordinatore, generare una coppia
di chiavi SSH dedicata a questa sessione per ridurre l'esposizione della
password nei comandi successivi, da installare su ESXi per
autenticazione a chiave.

**Comando/i**:

    mkdir -p "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$HOME/.ssh/forge_ai_esxi_ed25519" -N "" -C "forge-ai-esxi-validation-session"

**Osservato**: chiave generata con successo.
Fingerprint: `SHA256:c0LcM2u5bfbQVqgpQHQQgqibq31Bi9FW1yPdSf/VTFo forge-ai-esxi-validation-session`.
File creati: `~/.ssh/forge_ai_esxi_ed25519` (privata, 432 byte) e
`~/.ssh/forge_ai_esxi_ed25519.pub` (114 byte). Questa chiave è **fuori
dal repository** (home directory dell'utente Windows), non soggetta a
`.gitignore` del progetto ma comunque mai avvicinata al repository.

**Stato**: fatto, ma vedi il problema più sotto — questa chiave non ha
funzionato con l'host per via del FIPS mode, sostituita da una chiave RSA
(voce successiva).

## 2026-08-28 (ora esatta non catturata) — Primo accesso a ESXi con password (plink) e installazione chiave pubblica ed25519

**Contesto**: primo test di connettività SSH verso l'host ESXi con la
password fornita fuori banda, poi installazione della chiave pubblica
appena generata per passare ad autenticazione a chiave.

**Comando/i**:

    PW=$(cat "/c/Users/danie/Documents/Claude/esxi.txt.txt")
    echo y | "/c/Program Files/PuTTY/plink.exe" -ssh -pw "$PW" root@192.168.1.133 "echo CONNECTED; uname -a; vmware -v"
    unset PW

**Osservato**:

    -- Keyboard-interactive authentication prompts from server: ------------------
    -- End of keyboard-interactive prompts from server ---------------------------
    CONNECTED
    VMkernel localhost.home-life.hub 8.0.2 #1 SMP Release build-22380479 Sep  4 2023 15:00:49 x86_64 x86_64 x86_64 ESXi
    VMware ESXi 8.0.2 build-22380479

**Comando/i** (installazione chiave pubblica):

    PW=$(cat "/c/Users/danie/Documents/Claude/esxi.txt.txt")
    PUBKEY=$(cat "$HOME/.ssh/forge_ai_esxi_ed25519.pub")
    echo y | "/c/Program Files/PuTTY/plink.exe" -ssh -pw "$PW" root@192.168.1.133 \
      "mkdir -p /etc/ssh/keys-root && grep -qxF '$PUBKEY' /etc/ssh/keys-root/authorized_keys 2>/dev/null && echo ALREADY_PRESENT || (echo '$PUBKEY' >> /etc/ssh/keys-root/authorized_keys && echo APPENDED); chmod 600 /etc/ssh/keys-root/authorized_keys; cat /etc/ssh/keys-root/authorized_keys"
    unset PW

**Osservato**: `APPENDED`, seguito dal contenuto del file (solo la riga
`ssh-ed25519 AAAA...C3NzaC1lZDI1NTE5AAAAIGoSpS/Fu9PhnG8JxjMmmaLyk6MOV97OgWML/OcugoWJ forge-ai-esxi-validation-session`,
nessuna password nell'output).

**Decisione presa**: usare `/etc/ssh/keys-root/authorized_keys` come
percorso, per analogia con la convenzione standard OpenSSH
`AuthorizedKeysFile /etc/ssh/keys-%u/authorized_keys` — confermata
corretta subito dopo leggendo `sshd_config` (vedi voce successiva), per
puro caso: non era stata ancora verificata quando è stata scelta, la
verifica è arrivata solo dopo il fallimento dell'autenticazione a chiave.

**Stato**: fatto (installazione del file), ma la chiave non ha
funzionato — vedi problema nella voce successiva.

## 2026-08-28 (ora esatta non catturata) — Problema: autenticazione a chiave ed25519 rifiutata

**Contesto**: test dell'autenticazione a chiave subito dopo
l'installazione della pubkey ed25519.

**Comando/i**:

    ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -i "$HOME/.ssh/forge_ai_esxi_ed25519" root@192.168.1.133 "echo KEYAUTH_OK; hostname"

**Osservato**:

    Warning: Permanently added '192.168.1.133' (ECDSA) to the list of known hosts.
    ** WARNING: connection is not using a post-quantum key exchange algorithm.
    ** This session may be vulnerable to "store now, decrypt later" attacks.
    ** The server may need to be upgraded. See https://openssh.com/pq.html
    root@192.168.1.133: Permission denied (publickey,keyboard-interactive).
    (exit code 255)

**Problema**: `Permission denied` nonostante la chiave pubblica fosse
correttamente installata nel file che `sshd_config` indica come
`AuthorizedKeysFile`. Diagnosi: letto `sshd_config` per intero via plink
con password (comando sotto) — ha rivelato `fipsmode yes` e liste
esplicite e ristrette di `kexalgorithms`, `ciphers`, `macs`,
`hostkeyalgorithms`, tutte conformi FIPS 140. Ipotesi: Ed25519 non è
un'primitiva approvata FIPS 140-2/140-3 (a differenza di RSA e delle
curve NIST P-256/P-384/P-521 usate altrove nella stessa config), quindi
il demone SSH in FIPS mode rifiuta chiavi Ed25519 anche se
sintatticamente installate correttamente. Non risolvibile lato repository
— è un vincolo dell'host stesso.

**Comando di diagnosi**:

    PW=$(cat "/c/Users/danie/Documents/Claude/esxi.txt.txt")
    echo y | "/c/Program Files/PuTTY/plink.exe" -ssh -pw "$PW" root@192.168.1.133 "grep -viE '^#' /etc/ssh/sshd_config | grep -v '^$'"
    unset PW

**Osservato** (direttive attive rilevanti, elenco completo):

    allowstreamlocalforwarding no
    allowtcpforwarding no
    banner /etc/issue
    challengeresponseauthentication yes
    ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
    clientalivecountmax 3
    clientaliveinterval 200
    fipsmode yes
    gatewayports no
    hostbasedauthentication no
    hostkeyalgorithms ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-256,rsa-sha2-512
    ignorerhosts yes
    kexalgorithms ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256
    loglevel info
    macs hmac-sha2-256,hmac-sha2-512
    maxstartups 10:30:100
    permitrootlogin yes
    permittunnel no
    permituserenvironment no
    printmotd yes
    rekeylimit 1G, 1H
    syslogfacility auth
    tcpkeepalive yes
    usepam yes
    x11forwarding no
    subsystem sftp /usr/lib/vmware/openssh/bin/sftp-server -f LOCAL5 -l INFO
    strictmodes yes
    passwordauthentication no
    permitemptypasswords no
    hostkey /etc/ssh/ssh_host_rsa_key
    hostkey /etc/ssh/ssh_host_ecdsa_key
    compression no
    authorizedkeysfile /etc/ssh/keys-%u/authorized_keys

Nota: `passwordauthentication no` — il login iniziale con `-pw` di plink
funziona comunque perché passa da `keyboard-interactive`/PAM
(`usepam yes`), non dal metodo "password" classico SSH; per questo il
piano del coordinatore ("plink -pw per il primo accesso") ha funzionato
anche con questa direttiva a `no`.

**Correzione applicata**: generata una seconda coppia di chiavi, questa
volta RSA 3072 bit (algoritmo esplicitamente in whitelist FIPS, via
`rsa-sha2-256`/`rsa-sha2-512` in `hostkeyalgorithms`/di fatto usato anche
per `pubkeyacceptedalgorithms` di default in OpenSSH recenti). Non è un
bug di repository, quindi nessun commit: è un vincolo dell'ambiente
(host ESXi in FIPS mode) documentato qui.

**Stato**: risolto con la chiave RSA (vedi voce successiva). La chiave
ed25519 resta installata in `authorized_keys` sull'host, inutilizzata (non
rimossa per non rischiare di rompere altro con azioni aggiuntive non
necessarie sull'host; è comunque innocua, una pubkey in più che
semplicemente non verrà mai usata con successo in FIPS mode).

## 2026-08-28 (ora esatta non catturata) — Generazione e installazione chiave RSA, verifica funzionante

**Comando/i**:

    ssh-keygen -t rsa -b 3072 -f "$HOME/.ssh/forge_ai_esxi_rsa" -N "" -C "forge-ai-esxi-validation-session-rsa"

**Osservato**: chiave generata.
Fingerprint: `SHA256:tMqzeVbu0iBG5NIF5CenQDvZOAm8bXjPugZu8UpmzmU forge-ai-esxi-validation-session-rsa`.

**Comando/i** (installazione):

    PW=$(cat "/c/Users/danie/Documents/Claude/esxi.txt.txt")
    PUBKEY=$(cat "$HOME/.ssh/forge_ai_esxi_rsa.pub")
    echo y | "/c/Program Files/PuTTY/plink.exe" -ssh -pw "$PW" root@192.168.1.133 "echo '$PUBKEY' >> /etc/ssh/keys-root/authorized_keys; chmod 600 /etc/ssh/keys-root/authorized_keys; cat /etc/ssh/keys-root/authorized_keys"
    unset PW

**Osservato**: il file ora contiene due righe (la ed25519 inutilizzabile
+ la nuova RSA). Nessuna password nell'output.

**Comando/i** (verifica):

    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$HOME/.ssh/forge_ai_esxi_rsa" root@192.168.1.133 "echo KEYAUTH_OK; hostname"

**Osservato**:

    ** WARNING: connection is not using a post-quantum key exchange algorithm.
    ** This session may be vulnerable to "store now, decrypt later" attacks.
    ** The server may need to be upgraded. See https://openssh.com/pq.html
    KEYAUTH_OK
    localhost.localdomain

**Osservazione**: il warning "not using a post-quantum key exchange" è
un avviso standard del client OpenSSH recente (non un errore) quando il
server non offre un KEX post-quantum — atteso, dato l'elenco
`kexalgorithms` visto sopra (nessuno è PQ). Non è un problema per questo
lavoro, solo un avviso informativo del client.

**Decisione presa**: da qui in avanti, tutti i comandi verso l'host ESXi
usano `ssh -i "$HOME/.ssh/forge_ai_esxi_rsa" root@192.168.1.133`
(autenticazione a chiave), non più `plink -pw`. La password letta dal
file esterno non viene più usata per il resto della sessione salvo
necessità impreviste.

**Stato**: fatto. Autenticazione a chiave funzionante e verificata.

## 2026-08-28 (ora esatta non catturata) — Ricognizione host: datastore, CPU, memoria, VM esistenti, rete

**Contesto**: raccogliere i dati reali dell'host necessari per la Fase 0
(creazione VM) — confrontare con quanto descritto nell'handoff
("datastore NVMe piccolo 180GB liberi" + "pool ~5TB").

**Comando/i**:

    SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i $HOME/.ssh/forge_ai_esxi_rsa root@192.168.1.133"
    $SSH "esxcli storage filesystem list"
    $SSH "esxcli hardware cpu global get; esxcli system version get"
    $SSH "vim-cmd hostsvc/hosthardware | grep -A2 numCpu"
    $SSH "esxcli hardware memory get 2>&1 | head -5"
    $SSH "vim-cmd vmsvc/getallvms"
    $SSH "esxcli network vswitch standard list; esxcli network vswitch standard portgroup list"

**Osservato — datastore (`esxcli storage filesystem list`)**:

    Mount Point                                        Volume Name                                 UUID                                 Mounted  Type             Size           Free
    -------------------------------------------------  ------------------------------------------  -----------------------------------  -------  ------  -------------  -------------
    /vmfs/volumes/600d9cc6-915fbb51-f64b-d8d385d87c24  DS132_DS01_SATA_1TB                         600d9cc6-915fbb51-f64b-d8d385d87c24     true  VMFS-6   999922073600   591568830464
    /vmfs/volumes/600db95c-59132542-33a3-d8d385d87c24  DS132_DS02_SATA_1TB                         600db95c-59132542-33a3-d8d385d87c24     true  VMFS-6   999922073600   997431705600
    /vmfs/volumes/6a0ecede-36d70118-73b5-d8d385d87c24  DS132_DS03_SATA_1TB                         6a0ecede-36d70118-73b5-d8d385d87c24     true  VMFS-6   999922073600   998397444096
    /vmfs/volumes/6a11abfe-a3433923-789b-40a8f055c48c  DS132_DS01_SSD_256GB                        6a11abfe-a3433923-789b-40a8f055c48c     true  VMFS-6   239981297664    45184188416
    /vmfs/volumes/6a11caec-c7e247f8-6325-40a8f055c48c  DS132_DS04_SATA_2TB                         6a11caec-c7e247f8-6325-40a8f055c48c     true  VMFS-6  2000112582656  1224298463232
    /vmfs/volumes/6a158b18-150b0d8c-90d8-40a8f055c48c  DS132_DS02_SSD_256GB                        6a158b18-150b0d8c-90d8-40a8f055c48c     true  VMFS-6   239981297664    10735321088
    /vmfs/volumes/6a91690e-79d7dcf6-a927-001b21e7d76e  datastore1                                  6a91690e-79d7dcf6-a927-001b21e7d76e     true  VMFS-6   362387865600   360873721856
    /vmfs/volumes/6a91690d-eac44959-2d46-001b21e7d76e  OSDATA-6a91690d-eac44959-2d46-001b21e7d76e  6a91690d-eac44959-2d46-001b21e7d76e     true  VMFSOS   128580583424   124127281152
    /vmfs/volumes/b67455de-254faef7-f8ae-2f039b5dad25  BOOTBANK1                                   b67455de-254faef7-f8ae-2f039b5dad25     true  vfat       4293591040     3996778496
    /vmfs/volumes/5996ff6e-3045ec7e-7497-c870866b06ae  BOOTBANK2                                   5996ff6e-3045ec7e-7497-c870866b06ae     true  vfat       4293591040     4293525504

**Osservato — CPU**:

    CPU Packages: 1
    CPU Cores: 12
    CPU Threads: 24
    Hyperthreading Active: true
    Hyperthreading Supported: true
    Hyperthreading Enabled: true
    HV Support: 3
    Product: VMware ESXi
    Version: 8.0.2
    Build: Releasebuild-22380479
    Update: 2
    Patch: 0

`vim-cmd hostsvc/hosthardware`: `numCpuPackages = 1, numCpuCores = 12,
numCpuThreads = 24, hz = 2693508973`. Coerente con la specifica
dell'handoff (12 core / 24 thread disponibili).

**Osservato — memoria**: `Physical Memory: 137358831616 Bytes` (~127.9
GiB, arrotondato a "128 GB fisici" nell'handoff), `Reliable Memory: 0
Bytes`, `NUMA Node Count: 1`.

**Osservato — VM esistenti** (`vim-cmd vmsvc/getallvms`):

    Vmid  Name                       File                                                    Guest OS              Version
    1     Micro01                    [DS132_DS01_SSD_256GB] Micro01/Micro01.vmx               ubuntu64Guest         vmx-19
    2     VMware vCenter Server 8    [DS132_DS04_SATA_2TB] VMware vCenter Server 8/....vmx     other3xLinux64Guest   vmx-10
    3     GestioneAffitti_DR         [DS132_DS01_SATA_1TB] GestioneAffitti_DR/....vmx          winXPProGuest         vmx-08
    5     CLAUDE-CODE-TEST2          [DS132_DS02_SSD_256GB] CLAUDE-CODE-TEST2/....vmx          ubuntu64Guest         vmx-21

Nessuna di queste VM viene toccata in questo lavoro (mandato limitato
alla VM che creo io).

**Osservato — rete**:

    vSwitch0: Uplinks vmnic1,vmnic0, Portgroups: Management Network
    vSwitch1: Uplinks vmnic2,vmnic3, Portgroups: VM Network, VM Network 1

    Name                Virtual Switch  Active Clients  VLAN ID
    Management Network  vSwitch0                     1        0
    VM Network          vSwitch1                     0        0
    VM Network 1        vSwitch1                     2        0

**Problema / scostamento dall'handoff rilevato**: nessun dispositivo
NVMe esiste su questo host, e non esiste un singolo pool da ~5TB. Vedi
diagnosi dettagliata e decisione nella voce successiva.

**Stato**: fatto (raccolta dati). La decisione sul mapping datastore è
nella voce seguente.

## 2026-08-28 (ora esatta non catturata) — Diagnosi: nessun NVMe, nessun pool da 5TB — mapping datastore reale

**Contesto**: l'handoff descrive "un datastore NVMe piccolo (180 GB
liberi)" per il disco di sistema e "un pool più grande da circa 5 TB" per
il disco dati. I dati raccolti nella voce precedente non confermano
questa topologia.

**Comando/i** (approfondimento sui device fisici sotto ogni datastore):

    $SSH "esxcli storage vmfs extent list"
    $SSH "esxcli storage core device list | grep -E 'Device Display Name|Devfs Path|Size:|Is SSD|Is Local|^naa|^t10|^mpx'"

**Osservato**:

    Volume Name            Device Name (troncato)                          Partition
    DS132_DS01_SATA_1TB    t10.ATA_____WDC_WD1002FAEX2D00Z3A0...            1
    DS132_DS02_SATA_1TB    t10.ATA_____ST1000DM0032D1ER162...               1
    DS132_DS03_SATA_1TB    t10.ATA_____ST1000DM0032D9YN162...               1
    DS132_DS01_SSD_256GB   t10.ATA_____SSDSCKKB240G8R...049B240J            1
    DS132_DS04_SATA_2TB    t10.ATA_____SAMSUNG_HD204UI...                   1
    DS132_DS02_SSD_256GB   t10.ATA_____SSDSCKKB240G8R...048Y240J            1
    datastore1             t10.ATA_____ST9500420AS...                      8
    OSDATA-...             t10.ATA_____ST9500420AS...  (stesso disco)      7

    Dettaglio device (Is Local / Is SSD):
    WDC_WD1002FAEX (1TB)    Is Local: true, Is SSD: false   (HDD SATA)
    ST9500420AS (500GB)     Is Local: true, Is SSD: false   (HDD SATA, ospita sia OSDATA che datastore1)
    ST1000DM0032 x2 (1TB)   Is Local: true, Is SSD: false   (HDD SATA)
    SSDSCKKB240G8R x2       Is Local: true, Is SSD: true    (SSD SATA, 256GB nominali)
    SAMSUNG HD204UI (2TB)   Is Local: true, Is SSD: false   (HDD SATA)

**Diagnosi**: tutti i dispositivi sono SATA (dischi meccanici Western
Digital/Seagate/Samsung, più due SSD SATA da 256GB) — **nessun
dispositivo NVMe è presente su questo host**. La somma di tutto lo
storage libero su tutti i datastore VM (esclusi BOOTBANK e OSDATA, che
sono partizioni di sistema ESXi non destinate a storage VM) è
591+997+998+45+1224+10.7+360 ≈ 4226 GB liberi in totale, distribuiti su
**sette datastore separati**, non un singolo pool da ~5TB.

Questo è uno scostamento reale tra la descrizione dell'handoff (scritta
da chi ha visto l'host "ieri sera", probabilmente da vSphere Client con
una vista aggregata o un ricordo approssimativo) e lo stato effettivo
rilevato via `esxcli`/SSH questa sessione. Non è un bug di repository:
è un fatto sull'host, documentato qui con la stessa onestà richiesta per
i limiti ambientali.

**Decisione presa (con motivazione)**: dato che non esiste un vero
"datastore NVMe piccolo" né un vero "pool da 5TB", scelgo i due
datastore che meglio approssimano i due ruoli richiesti dal piano
(un volume piccolo e isolato per il disco di sistema, un volume grande
per il disco dati), privilegiando l'assenza di conflitto con le VM di
produzione già presenti sull'host:

- **Disco di sistema (~60GB)** → `datastore1`
  (`t10.ATA_____ST9500420AS...`, 337.5GB totali secondo `df -h`
  sull'host, 360GB liberi secondo `esxcli`, nessuna VM già presente).
  Motivazione: è l'unico datastore completamente vuoto e non
  taggato per un ruolo specifico (a differenza dei "DS132_DSxx" che
  fanno parte di uno schema di naming esistente con VM di produzione
  sopra), quindi il più sicuro per isolare la VM di questo collaudo
  senza toccare risorse di altri workload. Non è flash (è un HDD SATA
  da 500GB), quindi non replica la caratteristica "NVMe" richiesta
  dall'handoff, ma è l'analogo più vicino per ruolo (piccolo, dedicato,
  separato dal disco dati).

- **Disco dati (300-500GB)** → `DS132_DS02_SATA_1TB`
  (`t10.ATA_____ST1000DM0032D1ER162...`, ~931 GiB totali, 997GB liberi
  secondo `esxcli`, **nessuna VM attualmente presente**). Motivazione:
  tra i candidati "grandi" (DS02_SATA_1TB, DS03_SATA_1TB, DS04_SATA_2TB)
  è quello scelto perché completamente vuoto come DS03, ma con
  precedenza arbitraria numerica (DS02 prima di DS03); DS04_SATA_2TB
  pur avendo più spazio libero in assoluto (1224GB) ospita già la VM di
  produzione "VMware vCenter Server 8" e viene quindi evitato per non
  condividere contesa I/O con un servizio di produzione critico. Un
  disco dati thin da 300-500GB su un datastore da ~931GB con ~997GB
  liberi e nessun altro tenant lascia ampio margine (~500GB residui nel
  caso pessimo di allocazione massima) senza avvicinarsi a occupazione
  critica.

Questo scostamento e la scelta verranno riportati nel riepilogo finale
come richiesto dal piano ("il nome del datastore da 5TB usato, per
riferimento futuro") — con la precisazione che non si tratta di un vero
pool da 5TB ma del miglior analogo disponibile realmente sull'host,
`DS132_DS02_SATA_1TB`.

**Stato**: fatto (diagnosi e decisione). Nessun bug di repository
coinvolto — limite/scostamento ambientale documentato.

## 2026-08-28 13:2x UTC circa — Download, verifica e upload ISO Ubuntu Server 24.04

**Contesto**: messaggio del coordinatore ricevuto durante il lavoro,
con istruzione esplicita di NON usare ISO eventualmente già presenti sui
datastore dell'host (provenienza/versione ignota) e di scaricare invece
un'ISO fresca dalla fonte ufficiale (`https://releases.ubuntu.com/24.04/`),
verificarla con `SHA256SUMS` dalla stessa directory, poi caricarla sul
datastore scelto per il disco di sistema della VM.

**Comando/i** (download SHA256SUMS):

    mkdir -p "$HOME/Downloads/forge-ai-iso"
    cd "$HOME/Downloads/forge-ai-iso"
    curl -fSL -o SHA256SUMS "https://releases.ubuntu.com/24.04/SHA256SUMS"
    cat SHA256SUMS

**Osservato** (contenuto integrale del file al momento del download):

    faabcf33ae53976d2b8207a001ff32f4e5daae013505ac7188c9ea63988f8328 *ubuntu-24.04.3-desktop-amd64.iso
    c3514bf0056180d09376462a7a1b4f213c1d6e8ea67fae5c25099c6fd3d8274b *ubuntu-24.04.3-live-server-amd64.iso
    c74833a55e525b1e99e1541509c566bb3e32bdb53bf27ea3347174364a57f47c *ubuntu-24.04.3-wsl-amd64.wsl
    3a4c9877b483ab46d7c3fbe165a0db275e1ae3cfe56a5657e5a47c2f99a99d1e *ubuntu-24.04.4-desktop-amd64.iso
    e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433 *ubuntu-24.04.4-live-server-amd64.iso
    9b2f7730dc68227dd04a9f3e5eab86ad85caf556b8606ad94f1f29ff5c4fd3f5 *ubuntu-24.04.4-wsl-amd64.wsl

**Decisione presa**: usare `ubuntu-24.04.4-live-server-amd64.iso` (la
versione point-release più recente disponibile in quel momento nella
serie 24.04, coerente con la specifica "24.04.x" dell'handoff).

**Comando/i** (download ISO, ~3.17 GiB):

    ISO="ubuntu-24.04.4-live-server-amd64.iso"
    curl -fSL -o "$ISO" "https://releases.ubuntu.com/24.04/$ISO"

**Osservato**: download completato, HTTP 200, 3.2G scritti, velocità
media ~10MB/s, nessun errore di trasferimento riportato da curl.

**Comando/i** (verifica checksum):

    sha256sum ubuntu-24.04.4-live-server-amd64.iso
    grep "live-server-amd64.iso" SHA256SUMS | grep "24.04.4"

**Osservato**:

    e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433 *ubuntu-24.04.4-live-server-amd64.iso
    e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433 *ubuntu-24.04.4-live-server-amd64.iso

**Esito verifica**: **checksum SHA256 corrispondente esattamente**
(`e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433`).
ISO genuina e integra.

**Tentativo scartato**: prima di scaricare sulla macchina Windows, è
stato verificato se l'host ESXi stesso avesse accesso diretto a
Internet per scaricare con `wget` (BusyBox) risparmiando un passaggio.
Risultato: `wget --spider https://releases.ubuntu.com/24.04/` dall'host
ha restituito `Connecting to releases.ubuntu.com
([2620:2d:4002:1::107]:443) / wget: error getting response: Cannot
assign requested address` — la risoluzione DNS ha preferito un record
AAAA (IPv6) e l'host non ha una rotta IPv6 funzionante verso Internet
sul vSwitch di management. BusyBox `wget` su ESXi 8 non espone
un'opzione `-4`/`--inet4-only` per forzare IPv4 (elenco flag verificato
con `wget` senza argomenti: solo `-c/--continue`, `--spider`, `-q`,
`-O`, `-o`, `--header`, `-Y/--proxy`, `--no-check-certificate`, `-P`,
`-S`, `-U`). Non approfondito oltre (es. forzando un IP letterale) perché
il download dalla macchina Windows con verifica locale del checksum è
comunque la via richiesta esplicitamente dal coordinatore ed è già
riuscita; non è un bug di repository, è una nota informativa su un
limite di rete dell'host.

**Comando/i** (creazione cartella e upload sul datastore scelto per il
disco di sistema, `datastore1`, via scp verso il sottosistema sftp
dell'host):

    SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i $HOME/.ssh/forge_ai_esxi_rsa root@192.168.1.133"
    $SSH "mkdir -p /vmfs/volumes/datastore1/forge-ai-poc-ubuntu-01 /vmfs/volumes/datastore1/ISOs; df -h /vmfs/volumes/datastore1"
    scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$HOME/.ssh/forge_ai_esxi_rsa" \
      ubuntu-24.04.4-live-server-amd64.iso \
      root@192.168.1.133:/vmfs/volumes/datastore1/ISOs/ubuntu-24.04.4-live-server-amd64.iso

**Osservato**: `df -h /vmfs/volumes/datastore1` →
`VMFS-6 337.5G 1.4G 336.1G 0% /vmfs/volumes/datastore1` prima
dell'upload. Upload completato senza errori in 2m15s (`real 2m15.971s`).
Cartella `forge-ai-poc-ubuntu-01/` creata per ospitare in seguito i file
della VM (vmx, vmdk); cartella `ISOs/` per l'immagine.

**Stato**: fatto. ISO ufficiale scaricata, verificata bit-per-bit contro
il checksum pubblicato da Canonical, e caricata sul datastore scelto.
URL esatto usato: `https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso`,
checksum SHA256:
`e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433`.

## 2026-08-28 13:28 UTC — Chiusura backfill, ripresa piano con logging live

**Contesto**: messaggio del coordinatore che richiede la ricostruzione
completa di quanto già fatto (questa voce di chiusura) prima di
riprendere con il logging granulare in tempo reale per ogni comando
successivo, e un secondo messaggio che chiarisce il metodo di autoinstall
da usare per la Fase 0 (remaster ISO con cloud-init NoCloud incorporato
nel bootloader, non keystroke injection).

**Osservato**: nessuna password, chiave privata o altro segreto è
presente in questo file o in qualunque altro file scritto finora nel
repository — verificato a vista rileggendo ogni comando sopra prima di
scriverlo in questo documento.

**Stato**: fatto. Si riprende ora con la Fase 0 (creazione VM),
verificando prima la documentazione ufficiale Ubuntu autoinstall per la
sintassi esatta del remaster ISO, come richiesto.
