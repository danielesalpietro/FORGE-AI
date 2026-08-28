# 01 — Fase 0: preparazione dell'installazione automatica (autoinstall)

## 2026-08-28 13:2x UTC — Ricerca del meccanismo ufficiale di autoinstall Ubuntu 24.04

**Contesto**: dopo l'upload dell'ISO ufficiale (voce 00), il coordinatore ha
chiesto di procedere con un'installazione non presidiata basata su
remaster dell'ISO (cloud-init NoCloud incorporato nel bootloader), invitando
comunque a preferire un meccanismo ufficiale più robusto se la
documentazione ne indicasse uno migliore. Prima di eseguire qualunque
comando xorriso ho verificato la documentazione ufficiale, come richiesto
dalle regole di ingaggio del progetto.

**Comando/i**:

    WebFetch https://ubuntu.com/server/docs/install/autoinstall-quickstart
    # redirect 301 -> https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html
    WebFetch https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html

**Osservato**: la pagina ufficiale copre due meccanismi, nessuno dei due
è un remaster dell'ISO:
1. Delivery via rete: `ds=nocloud-net;s=http://_gateway:3003/`.
2. Delivery via volume esterno: seed ISO separato creato con
   `cloud-localds ~/seed.iso user-data meta-data` (pacchetto
   `cloud-image-utils`), montato come secondo CD-ROM accanto all'ISO
   ufficiale non modificata, es.:

       kvm -no-reboot -m 2048 \
         -drive file=image.img,format=raw,cache=none,if=virtio \
         -drive file=~/seed.iso,format=raw,cache=none,if=virtio \
         -cdrom ~/Downloads/ubuntu-<versione>-live-server-amd64.iso

   Nota importante citata testualmente dalla documentazione: "The
   installer prompts for a confirmation before modifying the disk. To
   skip the need for a confirmation, interrupt the booting process, and
   add the `autoinstall` parameter to the kernel command line." — quindi
   **anche con il seed esterno, il parametro kernel `autoinstall` resta
   necessario** per l'installazione realmente non presidiata; senza,
   l'installer si ferma comunque a un prompt di conferma.

**Decisione (poi superata, vedi sotto)**: dato che il parametro kernel
serve comunque, ho valutato il remaster dell'ISO principale (solo per
editare `grub.cfg` e aggiungere il parametro di default, senza toccare lo
squashfs) come il modo per evitare un intervento a tastiera dal vivo sulla
console — coerente con l'istruzione esplicita ricevuta dal coordinatore in
quel momento. Questa decisione è stata poi annullata (vedi la voce "Stop
al remaster" più sotto): esiste una console remota vera su questa VM
ESXi, quindi il problema che il remaster risolve (nessuna console
interattiva disponibile) non si applica qui.

**Stato**: fatto (ricerca), decisione successivamente cambiata.

## 2026-08-28 13:3x UTC — Verifica sintassi xorriso, avvio ambiente di build

**Contesto**: prima di eseguire xorriso, verificare la sintassi esatta
contro fonti verificabili invece di usarla a memoria, come richiesto dalle
regole di ingaggio.

**Osservato dalla ricerca**:
- Un post di blog (thelinuxvault.net) documenta la sequenza classica:
  estrazione completa dell'ISO, aggiunta di `user-data`/`meta-data` nella
  root, edit di `boot/grub/grub.cfg` per aggiungere
  `autoinstall ds=nocloud;s=/cdrom/` alla entry di boot, poi rebuild con
  `xorriso -as mkisofs` con opzioni `--grub2-mbr`/`--grub2-boot-info`
  esplicite (richiede i binari grub locali corrispondenti).
- Una discussione ufficiale sulla mailing list bug-xorriso
  (lists.gnu.org, giugno 2024, Thomas Schmitt/autore di xorriso) descrive
  un metodo più leggero e nativo di xorriso: `-map file iso_path` per
  ogni file da aggiungere/sostituire, seguito da `-boot_image any replay`
  per replicare automaticamente il catalogo di boot El Torito esistente
  senza dover fornire a mano i binari MBR/EFI. Nella stessa discussione è
  documentato un bug noto (fisso in xorriso 1.5.7) che si manifesta
  **solo quando l'immagine di boot BIOS legacy stessa viene sostituita**
  — non è il mio caso, dato che intendevo modificare solo `grub.cfg` (un
  file di testo separato), non `boot/grub/i386-pc/eltorito.img`.

**Comando/i** (avvio Docker Desktop, non era in esecuzione):

    tasklist //FI "IMAGENAME eq Docker Desktop.exe"      # nessun processo
    "/c/Program Files/Docker/Docker/Docker Desktop.exe" &
    timeout 150 bash -c 'until docker info >/dev/null 2>&1; do sleep 5; done; echo DOCKER_READY'

**Osservato**: `DOCKER_READY` dopo l'avvio (circa 1-2 minuti).

**Comando/i** (container di lavoro):

    docker run -d --name forge-iso-build ubuntu:24.04 sleep infinity
    docker exec forge-iso-build bash -c "apt-get update -qq && apt-get install -y -qq xorriso squashfs-tools whois grub-pc-bin grub-efi-amd64-bin mtools"

**Osservato**: immagine `ubuntu:24.04` scaricata (digest
`sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517`).
Pacchetti installati con successo, xorriso risultante: `xorriso/noble
1:1.5.6-1.1ubuntu3 amd64`. Alcuni avvisi non bloccanti di `debconf`
("unable to initialize frontend: Dialog/Readline", "falling back to
Teletype") durante l'installazione di `grub-efi-amd64-signed` — normali
in un container senza TTY, non un errore.

**Stato**: fatto (setup ambiente). Container poi rimosso, vedi sotto.

## 2026-08-28 13:4x UTC — Copia ISO nel container e ispezione struttura di boot reale

**Contesto**: prima di modificare qualunque cosa, verificare la struttura
El Torito effettiva della ISO 24.04.4 scaricata (non fidarsi di esempi
scritti per altre versioni).

**Comando/i**:

    docker cp "$HOME/Downloads/forge-ai-iso/ubuntu-24.04.4-live-server-amd64.iso" forge-iso-build:/build_iso_orig.iso
    docker exec forge-iso-build bash -c "xorriso -indev /build_iso_orig.iso -report_el_torito plain"

**Osservato** (output integrale):

    xorriso 1.5.6 : RockRidge filesystem manipulator, libburnia project.
    xorriso : NOTE : Loading ISO image tree from LBA 0
    xorriso : UPDATE :    1072 nodes read in 1 seconds
    libisofs: NOTE : Found hidden El-Torito image for EFI.
    libisofs: NOTE : EFI image start and size: 1660121 * 2048 , 10160 * 512
    xorriso : NOTE : Detected El-Torito boot information which currently is set to be discarded
    Drive current: -indev '/build_iso_orig.iso'
    Media current: stdio file, overwriteable
    Media status : is written , is appendable
    Boot record  : El Torito , MBR protective-msdos-label grub2-mbr cyl-align-off GPT
    Media summary: 1 session, 1662827 data blocks, 3248m data,  907g free
    Volume id    : 'Ubuntu-Server 24.04.4 LTS amd64'
    El Torito catalog  : 998  1
    El Torito cat path : /boot.catalog
    El Torito images   :   N  Pltf  B   Emul  Ld_seg  Hdpt  Ldsiz         LBA
    El Torito boot img :   1  BIOS  y   none  0x0000  0x00      4         999
    El Torito boot img :   2  UEFI  y   none  0x0000  0x00  10160     1660121
    El Torito img path :   1  /boot/grub/i386-pc/eltorito.img
    El Torito img opts :   1  boot-info-table grub2-boot-info
    El Torito img blks :   2  2540
    [exited with code 0]

**Osservazione**: l'immagine di boot UEFI è "hidden" (embedded come
partizione GPT, non un file ordinario nell'albero ISO9660) — la ricetta
del blog (che assume un file `boot/grub/efi.img` esplicito nell'albero)
non era direttamente applicabile a questa ISO senza verifica aggiuntiva;
un motivo in più per preferire `-boot_image any replay` (che gestisce
questa combinazione MBR+GPT+El Torito automaticamente) rispetto a
ricostruire i flag mkisofs a mano.

**Comando/i** (estrazione del solo grub.cfg per prepararne la modifica):

    docker exec forge-iso-build bash -c "xorriso -indev /build_iso_orig.iso -osirrox on -extract /boot/grub/grub.cfg /extract/grub.cfg"
    cat /extract/grub.cfg

**Osservato** (contenuto integrale originale):

    set timeout=30

    loadfont unicode

    set menu_color_normal=white/black
    set menu_color_highlight=black/light-gray

    menuentry "Try or Install Ubuntu Server" {
    	set gfxpayload=keep
    	linux	/casper/vmlinuz  ---
    	initrd	/casper/initrd
    }
    menuentry "Ubuntu Server with the HWE kernel" {
    	set gfxpayload=keep
    	linux	/casper/hwe-vmlinuz  ---
    	initrd	/casper/hwe-initrd
    }
    grub_platform
    if [ "$grub_platform" = "efi" ]; then
    menuentry 'Boot from next volume' {
    	exit 1
    }
    menuentry 'UEFI Firmware Settings' {
    	fwsetup
    }
    else
    menuentry 'Test memory' {
    	linux16 /boot/memtest86+x64.bin
    }
    fi

**Stato**: fatto (ricognizione). Il file modificato preparato in questa
fase non è mai stato iniettato in una ISO (vedi stop più sotto), ma la
sua bozza resta salvata nello scratchpad locale della sessione, fuori dal
repository.

## 2026-08-28 13:4x UTC — Generazione chiave SSH dedicata alla VM e hash password casuale

**Contesto**: preparazione del contenuto `user-data`, seguendo
l'istruzione del coordinatore di usare solo autenticazione a chiave per
l'utente della VM e generare un hash di password casuale scartato subito
dopo (l'identity di autoinstall richiede comunque un campo `password`
valorizzato).

**Comando/i** (chiave dedicata, generata su questa macchina Windows, FUORI
dal repository):

    ssh-keygen -t ed25519 -f "$HOME/.ssh/forge_esxi_vm" -N "" -C "forge-ai-poc-controller-vm"

**Osservato**: chiave generata.
Fingerprint: `SHA256:UbRVltVykW/5u+k/NxgXkumqqgRfPRMZf1VNMXZ6meg forge-ai-poc-controller-vm`.
Nota: questa chiave usa ed25519 (non RSA) perché è per l'account
`forgeops` sull'sshd **della VM Ubuntu**, non per root su ESXi — l'sshd
di Ubuntu non è in FIPS mode (a differenza di quello ESXi visto nella
voce 00), quindi ed25519 è pienamente supportato lì.

**Comando/i** (hash password casuale, plaintext mai stampato in nessun
output di comando, generato ed eliminato solo in memoria del container):

    docker exec forge-iso-build bash -c '
      PW=$(openssl rand -base64 32)
      HASH=$(printf "%s" "$PW" | mkpasswd --method=sha-512 --stdin)
      unset PW
      echo -n "$HASH" > /tmp/pwhash.txt
    '

**Osservato**: hash generato, 106 caratteri, prefisso `$6$` (SHA-512
crypt). **Il valore dell'hash non viene riportato in questo logbook**,
per la stessa cautela usata per la password ESXi, anche se è un digest
unidirezionale e non la password in chiaro — l'accesso reale alla VM
avviene comunque solo per chiave (`allow-pw: false` +
`PasswordAuthentication no` impostato via late-commands), quindi questo
hash non è mai stato né sarà il meccanismo di autenticazione realmente
usato.

**Stato**: fatto. La chiave privata resta solo su questa macchina
Windows (`~/.ssh/forge_esxi_vm`), mai avvicinata al repository.

## 2026-08-28 13:4x UTC — Problema: MSYS/Git-Bash riscrive i path POSIX passati a docker.exe

**Contesto**: primo tentativo di leggere l'hash generato nel container
per iniettarlo nel file `user-data` locale.

**Comando/i (fallito)**:

    HASH=$(docker exec forge-iso-build cat /tmp/pwhash.txt)

**Osservato**: `cat: 'C:/Users/danie/AppData/Local/Temp/pwhash.txt': No
such file or directory` — Git Bash (MSYS2) riscrive automaticamente gli
argomenti che sembrano path POSIX assoluti (`/tmp/...`) in path Windows
prima di invocare un eseguibile nativo non-MSYS come `docker.exe`,
anche quando quel path è destinato a vivere *dentro* il container, non
sul filesystem Windows. L'effetto silenzioso è stato che `HASH` risultava
vuoto e il campo `password` nel file `user-data` è finito temporaneamente
con un valore vuoto (`password: ""`), un file YAML sintatticamente
valido ma semanticamente rotto (autoinstall lo avrebbe accettato senza
errori evidenti, con conseguenze imprevedibili sull'account).

**Causa radice**: comportamento noto di MSYS2/Git-Bash chiamato "path
conversion", non un bug del progetto.

**Correzione applicata (non è un bug di repository, quindi nessun
commit)**: anteporre `MSYS_NO_PATHCONV=1` ai comandi `docker exec`/`docker
cp` che referenziano path che devono restare letterali (cioè path dentro
il container, non sul filesystem Windows):

    HASH=$(MSYS_NO_PATHCONV=1 docker exec forge-iso-build cat /tmp/pwhash.txt)
    echo "hash length: ${#HASH}"   # 106, corretto

Il file `user-data` locale (fuori dal repository, nello scratchpad di
sessione) è stato poi corretto sostituendo il placeholder con l'hash
reale, verificato solo per lunghezza/prefisso senza mai stampare il
valore per intero:

    sed -i "s#password: \"\"#password: \"${HASH}\"#" "<scratchpad>/user-data-poc-controller.yaml"

**Stato**: risolto. Da qui in avanti, ogni comando `docker` verso questo
container che referenzia path che iniziano per `/` e non devono essere
tradotti viene prefissato con `MSYS_NO_PATHCONV=1`.

## 2026-08-28 13:4x UTC — Contenuto bozza `user-data`/`meta-data` (mai usato — vedi stop)

**Contesto**: bozza preparata per il remaster, salvata solo nello
scratchpad locale (`C:\Users\danie\AppData\Local\Temp\claude\...\scratchpad\`,
mai nel repository), poi non più utilizzata nella forma "file dentro
l'ISO" ma riadattata più sotto per la consegna via HTTP.

**Decisioni prese in quella bozza (motivazione)**:
- Nome VM/hostname: `poc-controller` (non specificato esplicitamente
  dall'handoff, che parla genericamente di "l'ospite"/"il control
  plane"; scelto per essere descrittivo e distinguibile dal target
  interno `poc-ubuntu-01`).
- Utente: `forgeops`, per coerenza con `config/defaults.yml:170`
  (`users.automation_user: forgeops`), lo stesso nome che il repository
  usa già per gli host interni.
- Storage: `match: size: smallest` sul disco per selezionare
  automaticamente il disco di sistema da 60GB invece di quello dati
  (300-500GB), senza hardcodare `/dev/sda`. Verificato che `smallest` è
  una parola chiave valida al pari di `largest` (già usata dal
  repository in `ansible/templates/ubuntu/user-data.j2`) tramite
  ricerca web (discourse.ubuntu.com, risultati di ricerca su
  "match: size: smallest" curtin). Layout GPT + ESP (1G) + /boot (2G) +
  LVM per / (42G su un VG che lascia margine), stessa struttura già
  presente e testata nel template esistente del repository, per non
  inventare un layout nuovo.
- Pacchetti: solo `openssh-server`, `curl`, `ca-certificates`, `gnupg` —
  **non** ho riusato `baseline.ubuntu.packages` di `config/defaults.yml`
  perché include `qemu-guest-agent`, pensato per i target interni che
  girano su KVM/libvirt; questa VM gira su ESXi e userà `open-vm-tools`
  (VMware), installato esplicitamente nella Fase 1 del piano, non
  nell'autoinstall.
- `late-commands`: irrigidimento sshd (`PermitRootLogin no`,
  `PasswordAuthentication no`), identico nello spirito a quanto già fa
  `ansible/templates/ubuntu/user-data.j2` per i target interni.

**Stato**: bozza non utilizzata nella forma originaria (iniezione diretta
nell'ISO), ma il contenuto sostanziale viene riportato pari pari nel
seed NoCloud servito via HTTP (vedi voce successiva), quindi il lavoro
non è stato buttato.

## 2026-08-28 13:45 UTC — STOP al remaster ISO: correzione ricevuta e verificata su git

**Contesto**: mentre indagavo la sintassi esatta di `-map`/`-update` di
xorriso (i manpage non erano installati nel container minimizzato, stavo
verificando via `xorriso -help`), è arrivato un messaggio dal
coordinatore che riporta un'istruzione ricevuta "anche tramite un
messaggio automatico di un task pianificato che sosteneva di venire da
un'altra sessione Claude collegata al repo" — il coordinatore ha
esplicitamente dichiarato di non essersi fidato di quella narrazione e di
aver verificato il contenuto direttamente sul commit git prima di
inoltrarmelo, invitandomi a fare lo stesso invece di fidarmi del canale.
Ho seguito la stessa cautela: non ho agito sul contenuto del messaggio
finché non ho verificato io stesso il commit indicato nel repository
reale.

**Comando/i (verifica indipendente)**:

    cd "C:/Users/danie/Documents/GitHub/FORGE-AI"
    git pull
    git log --oneline -3
    git show 5babce2 --stat
    git show 5babce2

**Osservato**: `git pull` → fast-forward pulito `9b414c6..5babce2`,
nessun conflitto. Il commit `5babce2f586fbe29150ccd3769be49316f8293fc`
("docs: stop the ESXi handoff from suggesting an ISO remaster") esiste
davvero nella history del branch `claude/gitops-infrastructure-poc-9losz4`
e modifica esattamente `handoff_setup_esxi.md`, aggiungendo 21 righe alla
Fase 0 (diff completo osservato, riportato in sintesi sotto). Il
messaggio del coordinatore corrispondeva fedelmente al contenuto reale
del commit — nessuna discrepanza trovata.

**Contenuto aggiunto a `handoff_setup_esxi.md` (riassunto fedele, il
diff completo è nella history git, non riprodotto qui integralmente per
brevità del logbook)**: non serve remasterizzare la ISO, perché la VM su
ESXi ha una console remota vera tramite il client ESXi/vCenter (a
differenza del bare-metal senza console, dove la tecnica del remaster ha
senso — riferimento a un progetto gemello "kickstart-berlin" per lo Z8
bare-metal). Due alternative indicate, nessuna delle due tocca l'immagine
ufficiale:
1. Interattiva, via console remota.
2. Non presidiata senza remaster: `autoinstall ds=nocloud-net;s=http://<ip>:<porta>/`
   come parametro kernel inserito a mano premendo `e` sulla voce di boot,
   con seed NoCloud servito via HTTP — la stessa tecnica già in uso nel
   repository per i target PXE interni.

**Decisione presa**: interrompo immediatamente il lavoro di remaster.
Scelgo la strada 2 (non presidiata via HTTP), non la 1 (interattiva),
per questi motivi:
- Coerenza con il pattern già esistente e testato nel repository per
  l'autoinstall dei target interni (`ds=nocloud;s=http://.../<host>/`
  in `ansible/templates/`), come esplicitamente suggerito.
- Riproducibilità: un intervento a tastiera su una console remota (anche
  se fatto una sola volta) non è scriptabile in modo affidabile con gli
  strumenti di automazione browser disponibili in questa sessione senza
  rischio di errori di battitura/timing su un editor GRUB minimale — la
  via HTTP resta un singolo parametro kernel inserito allo stesso modo,
  ma il contenuto che guida l'installazione (user-data) resta un file di
  testo verificabile, non un'interazione a schermo.
- Il file YAML `user-data` già preparato nella voce precedente resta
  quasi interamente riutilizzabile, cambia solo il meccanismo di
  consegna (HTTP invece di iniezione nell'ISO).

**Pulizia dell'ambiente di remaster abbandonato**:

    docker rm -f forge-iso-build

**Osservato**: `forge-iso-build` (output: `forge-iso-build`), container
rimosso. **Nota**: l'ISO ufficiale già caricata su
`/vmfs/volumes/datastore1/ISOs/ubuntu-24.04.4-live-server-amd64.iso`
(voce 00) **resta valida e viene riusata inalterata** — solo il lavoro di
modifica dell'immagine viene scartato, non il download/verifica/upload,
che restano parte del lavoro utile già fatto.

**Stato**: fatto. Si riprende ora preparando la consegna del seed
NoCloud secondo l'alternativa 2 indicata dal commit (`ds=nocloud-net`
via HTTP) — vedi però il problema di raggiungibilità di rete trovato
subito dopo, che ha portato a un adattamento del meccanismo di consegna.

## 2026-08-28 13:47 UTC — Preparazione seed NoCloud e IP LAN della macchina Windows

**Contesto**: prima di avviare un server HTTP temporaneo, servono i file
`user-data`/`meta-data` con i nomi esatti attesi dal datasource NoCloud
(senza estensione) e l'indirizzo IP della macchina Windows sulla stessa
subnet dell'host ESXi.

**Comando/i**:

    mkdir -p "<scratchpad>/nocloud-seed"
    cp "<scratchpad>/user-data-poc-controller.yaml" "<scratchpad>/nocloud-seed/user-data"
    cp "<scratchpad>/meta-data-poc-controller.yaml" "<scratchpad>/nocloud-seed/meta-data"

**Comando/i** (IP LAN, PowerShell):

    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.1.*" } | Select-Object IPAddress, InterfaceAlias

**Osservato**: `192.168.1.72` su `Ethernet 2` — stessa subnet /24
dell'host ESXi (`192.168.1.133`), coerente con l'assunzione dell'handoff
di rete piatta senza segmentazione più stretta.

**Stato**: fatto.

## 2026-08-28 13:48 UTC — Avvio server HTTP temporaneo per il seed, due problemi trovati e risolti/aggirati

**Contesto**: servire `user-data`/`meta-data` via HTTP da questa macchina
Windows perché la VM possa raggiungerli con
`ds=nocloud-net;s=http://192.168.1.72:8080/` durante l'installazione,
come indicato dal commit `5babce2`.

**Comando/i (primo tentativo)**:

    SCRATCH="<scratchpad>"
    docker run -d --name forge-nocloud-http -p 8080:8080 \
      -v "${SCRATCH}/nocloud-seed:/srv:ro" \
      python:3.12-alpine python3 -m http.server 8080 --directory /srv
    curl -s http://127.0.0.1:8080/user-data

**Osservato**: `404 File not found` sia su `/user-data` sia su
`/meta-data`, nonostante il bind mount risultasse configurato
correttamente (`docker inspect` → `Mounts` mostrava la sorgente/
destinazione corrette).

**Problema 1 — diagnosi**: `docker inspect forge-nocloud-http --format
'{{json .Config.Cmd}}'` ha rivelato che l'argomento `--directory /srv`
passato al comando del container era diventato
`--directory "C:/Program Files/Git/srv"` — di nuovo il "path conversion"
automatico di Git Bash/MSYS2 (stesso fenomeno già incontrato e già
descritto nella voce precedente per `docker exec`), questa volta
sull'argomento del comando eseguito *dentro* il container passato tramite
`docker run ... <image> <cmd...>`, non solo su `docker exec`.

**Correzione applicata (non è un bug di repository)**: ricreare il
container con `MSYS_NO_PATHCONV=1` anteposto all'intero comando `docker
run`:

    docker rm -f forge-nocloud-http
    MSYS_NO_PATHCONV=1 docker run -d --name forge-nocloud-http -p 8080:8080 \
      -v "${SCRATCH}/nocloud-seed:/srv:ro" \
      python:3.12-alpine python3 -m http.server 8080 --directory /srv

**Osservato**: `docker inspect ... Config.Cmd` ora mostra correttamente
`["python3","-m","http.server","8080","--directory","/srv"]`.
`curl http://127.0.0.1:8080/user-data` e `/meta-data` → entrambi `200`
in locale.

**Problema 2 — raggiungibilità dalla LAN**: test dall'host ESXi (come
proxy per la raggiungibilità dalla futura VM, che condividerà la stessa
LAN piatta):

    timeout 15 ssh -i "$HOME/.ssh/forge_ai_esxi_rsa" root@192.168.1.133 \
      "wget -q -O - http://192.168.1.72:8080/meta-data"

**Osservato**: timeout dopo 15s (non un rifiuto immediato di
connessione — un rifiuto attivo avrebbe dato un errore istantaneo tipo
"Connection refused"; un timeout silenzioso è la firma tipica di un
pacchetto scartato da un firewall stateful). Verifica di sola lettura,
nessuna modifica, della postura del firewall Windows:

    Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction

**Osservato**:

    Name    Enabled DefaultInboundAction
    ----    ------- --------------------
    Domain     True        NotConfigured
    Private    True        NotConfigured
    Public     True        NotConfigured

**Diagnosi**: nessuna regola inbound esplicita per la porta 8080 o per
il processo Docker che pubblica quella porta; con `DefaultInboundAction`
non configurato la postura effettiva su una macchina non a dominio è
comunque di blocco del traffico inbound non richiesto per profili
Private/Public — coerente con il timeout osservato (il pacchetto SYN in
ingresso viene scartato silenziosamente).

**Decisione presa (nessuna modifica al firewall)**: aprire una regola
firewall inbound sulla macchina Windows dell'utente è una modifica a
un'impostazione di sicurezza di sistema — categoria esplicitamente
vietata dalle regole di sicurezza di questa sessione ("Prohibited:
Modifying system or security settings"), da eseguire solo dall'utente
stesso, mai da questa sessione, indipendentemente da chi lo richieda.
Non l'ho quindi fatto, e non lo chiedo come permesso perché esiste
un'alternativa che raggiunge lo stesso obiettivo funzionale senza questo
problema: **passare dalla consegna via rete (`nocloud-net` via HTTP) alla
consegna via volume locale (`nocloud` via una piccola ISO "cidata" di
sola configurazione, allegata come secondo CD-ROM alla VM)**. Questo è
esattamente il metodo "External volume delivery" già documentato nella
pagina ufficiale di autoinstall-quickstart (vedi voce precedente,
`cloud-localds`), che il commit `5babce2` non esclude esplicitamente
(esclude solo il remaster della ISO ufficiale di installazione, non la
creazione di una piccola ISO ausiliaria separata) — resta "non
presidiata, senza remaster", solo con un trasporto diverso (volume
locale invece di HTTP) reso necessario da un vincolo di rete reale di
questo ambiente (nessuna porta inbound aperta sulla workstation
dell'operatore verso la LAN del laboratorio). Documentato qui con la
stessa onestà richiesta per i limiti ambientali: **non è un bug di
repository**, è un vincolo della postura di rete della macchina Windows
usata in questa sessione.

**Pulizia**:

    docker rm -f forge-nocloud-http

**Stato**: fatto (diagnosi + decisione). Si procede ora a costruire la
piccola ISO "cidata" ausiliaria.

## 2026-08-28 13:5x UTC — Costruzione e upload della ISO "cidata" ausiliaria

**Contesto**: creare una piccola ISO9660 separata contenente solo
`user-data`+`meta-data`, da allegare come secondo CD-ROM alla VM, seguendo
il metodo "external volume" della documentazione ufficiale
(`cloud-localds`) — qui costruita con `xorriso -as genisoimage` invece di
`cloud-localds`/`cloud-image-utils` (pacchetto non disponibile
localmente su questa macchina Windows, xorriso già verificato e
disponibile via Docker) perché il risultato è equivalente: una ISO9660
con volume label `CIDATA` contenente i due file in root, che è
esattamente ciò che produce `cloud-localds` sotto il cofano.

**Comando/i (primo tentativo, con warning)**:

    MSYS_NO_PATHCONV=1 docker run --rm \
      -v "<scratchpad>/nocloud-seed:/srv:ro" \
      -v "<scratchpad>:/out" \
      alpine:3.20 sh -c "apk add --no-cache xorriso; xorriso -as genisoimage -output /out/seed-poc-controller.iso -volid cidata -joliet -rock /srv/user-data /srv/meta-data"

**Osservato**: `xorriso : WARNING : -volid text does not comply to ISO
9660 / ECMA 119 rules` — lo standard ISO9660 livello 1 richiede il
volume ID in maiuscolo (set di caratteri ristretto); `cidata` minuscolo
non è conforme. ISO comunque scritta (186 settori), ma per sicurezza
(il datasource NoCloud confronta l'etichetta del volume, e vari sistemi
la normalizzano diversamente) l'ho rifatta in maiuscolo.

**Comando/i (rifatto, senza warning)**:

    rm -f "<scratchpad>/seed-poc-controller.iso"
    MSYS_NO_PATHCONV=1 docker run --rm \
      -v "<scratchpad>/nocloud-seed:/srv:ro" \
      -v "<scratchpad>:/out" \
      alpine:3.20 sh -c "apk add --no-cache xorriso; xorriso -as genisoimage -output /out/seed-poc-controller.iso -volid CIDATA -joliet -rock /srv/user-data /srv/meta-data"

**Osservato**: nessun warning. `ISO image produced: 186 sectors`,
`Writing to 'stdio:/out/seed-poc-controller.iso' completed successfully`.
File risultante: 380928 byte.
SHA256: `6eec77dbd87de7f0185631d0797de07a8424e804978ed7dd4f2ebb1e8979ae98`
(hash calcolato localmente per tracciabilità — non c'è un checksum
"ufficiale" da confrontare, dato che il file è generato da me, non
scaricato).

**Comando/i (upload)**:

    scp -i "$HOME/.ssh/forge_ai_esxi_rsa" "<scratchpad>/seed-poc-controller.iso" \
      root@192.168.1.133:/vmfs/volumes/datastore1/ISOs/seed-poc-controller.iso

**Osservato**: upload completato.
`ls -la /vmfs/volumes/datastore1/ISOs/` sull'host mostra entrambi i
file:

    -rw-r--r--    1 root     root        380928 Aug 28 13:53 seed-poc-controller.iso
    -rw-r--r--    1 root     root     3405469696 Aug 28 13:28 ubuntu-24.04.4-live-server-amd64.iso

**Stato**: fatto. Le due ISO necessarie sono ora sul datastore scelto
per il disco di sistema (`datastore1`). Si procede alla creazione vera e
propria della VM (dischi, file .vmx, registrazione).
