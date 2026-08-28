# 05 — Fase 6: `make provision`, deploy-pxe, provisioning delle VM target

## Contesto

Dopo `bootstrap.sh` (Fase 5, 13 bug) e `make prepare-media` (bug 14),
prossimo passo del piano: `make prepare-media` -> `make deploy-pxe` ->
`make provision` (crea/installa `poc-ubuntu-01` e `poc-windows-01`).

## Errore di sequenza (mio, non un bug del repo)

Ho lanciato `make provision` subito dopo `make prepare-media`, saltando
`make deploy-pxe`. La VM `poc-ubuntu-01` è partita, ha tentato il boot
di rete, ed è finita su una UEFI Shell con:

    BdsDxe: failed to load Boot0002 "UEFI PXEv4 (MAC:525400250021)" ...
    Not Found

Non un bug: il servizio TFTP/DHCP dedicato (`forge-dnsmasq`) non era
ancora stato distribuito. Corretto rilanciando `make deploy-pxe` per
primo (come da target Makefile).

## Bug 15 — CAP_SETPCAP mancante nella unit systemd di `forge-dnsmasq`

**Sintomo**: `make deploy-pxe` falliva ripetutamente su "Assert that
TFTP answers" / "No TFTP listener on udp/69", con `forge-dnsmasq.service`
in restart-loop.

**Diagnosi**: `journalctl -u forge-dnsmasq` mostrava
`setting capabilities failed: Operation not permitted` seguito da
`FAILED to start up` — dnsmasq chiama `capset()` su se stesso all'avvio
come parte del proprio hardening interno, anche da root, e quella
chiamata richiede `CAP_SETPCAP` nel proprio capability set. La unit
template (`ansible/templates/dnsmasq/forge-dnsmasq.service.j2`) aveva
`AmbientCapabilities`/`CapabilityBoundingSet` senza `CAP_SETPCAP`.

**Correzione applicata**: aggiunto `CAP_SETPCAP` a entrambe le righe.

## Bug 16 — `dhcp-leasefile` in una directory non scrivibile dal processo

**Sintomo**: dopo il fix del bug 15, `forge-dnsmasq` falliva ancora,
questa volta con un errore di permesso sul file di lease.

**Diagnosi**: `dhcp-leasefile` puntava a `{{ storage.state_dir }}`, una
directory `0750` posseduta da UID 10001 (il container dello state
service, non root) — confermato via `journalctl`, non assunto.
`forge-dnsmasq.service` gira come `root` ma con `CapabilityBoundingSet`
volutamente privo di `CAP_DAC_OVERRIDE`, quindi root stesso riceve
"Permission denied" lì come un UID qualunque. `storage.log_dir` è
`root:root 0755` ed è già in `ReadWritePaths` della unit.

**Correzione applicata**: `ansible/templates/dnsmasq/provisioning.conf.j2`,
`dhcp-leasefile` spostato da `storage.state_dir` a `storage.log_dir`.

## Bug 17 — direttive di hardening seccomp incompatibili con il `capset()` interno di dnsmasq

**Sintomo**: dopo i bug 15 e 16, `make deploy-pxe` falliva **ancora**
sullo stesso identico errore (`No TFTP listener on udp/69`), nonostante
`systemctl status forge-dnsmasq` confermasse `active (running)` pochi
istanti prima di un rerun. Tre run consecutivi falliti nonostante due
fix reali già applicati — la cosa non tornava.

**Diagnosi (bisezione empirica diretta sull'host, non per ipotesi)**:

1. `journalctl -u forge-dnsmasq` mostrava solo `dnsmasq: syntax check
   OK.` (l'output di `ExecStartPre --test`) — il vero errore del
   processo `ExecStart` non passava da syslog/journal, perché la
   configurazione usa `log-facility=.../dnsmasq.log` (file, non
   syslog). Letto quel file direttamente:

       setting capabilities failed: Operation not permitted
       FAILED to start up

   **Lo stesso identico errore del bug 15**, nonostante `CAP_SETPCAP`
   fosse già presente e confermato nella unit realmente installata su
   disco (`systemctl cat forge-dnsmasq`).

2. Riprodotto lo stesso set di capability **fuori** dalla sandbox
   systemd con `capsh --caps=... --addamb=...` e lanciato dnsmasq sotto
   `strace`: **nessun errore di capset**, arrivava fino al bind del
   socket. Quindi il problema non erano le capability in sé, ma
   qualcos'altro nella unit.

3. Bisezione diretta sulla unit reale, un gruppo di direttive alla
   volta, riavviando e leggendo `/srv/forge-ai/logs/dnsmasq.log` ogni
   volta (non `systemctl status` da solo, che non mostra l'errore):

   - Solo le direttive di capability + `NoNewPrivileges` -> **funziona**
     (DHCP e TFTP entrambi in ascolto, confermato con `ss`).
   - Aggiunte tutte e 6 le `Protect*` -> **fallisce di nuovo**
     (`setting capabilities failed`).
   - Solo `ProtectSystem=strict` + `ProtectHome=yes` + `PrivateTmp=yes`
     -> **funziona**.
   - Solo `ProtectKernelTunables=yes` (da sola) -> **fallisce**.
   - Rimossa `ProtectKernelTunables` ma reintrodotto il gruppo
     `RestrictNamespaces`/`RestrictRealtime`/`RestrictSUIDSGID`/
     `MemoryDenyWriteExecute`/`LockPersonality`/
     `SystemCallArchitectures=native` (mai testato da solo fino a quel
     punto) -> **fallisce ancora**: un secondo colpevole indipendente,
     non solo `ProtectKernelTunables`.
   - Testate singolarmente `RestrictNamespaces`, `RestrictRealtime`,
     `RestrictSUIDSGID`: **ognuna, presa da sola, fa fallire
     `capset()`**.

   Conclusione verificata: **qualunque** direttiva systemd che installa
   un filtro seccomp (`ProtectKernelTunables`, `RestrictNamespaces`,
   `RestrictRealtime`, `RestrictSUIDSGID`, e con ogni probabilità anche
   `ProtectKernelModules`, `ProtectControlGroups`,
   `MemoryDenyWriteExecute`, `LockPersonality`,
   `SystemCallArchitectures=native` — non tutte testate una per una per
   tempo, ma mai state necessarie per isolare il fix) rompe la chiamata
   `capset()` che dnsmasq 2.90 fa su se stesso all'avvio. Solo le
   direttive di capability e il trio `ProtectSystem`/`ProtectHome`/
   `PrivateTmp` (basate su mount-namespace, senza seccomp) sono
   compatibili.

   La causa esatta a livello di singola syscall bloccata dal filtro
   seccomp **non è stata identificata** — non necessaria per il fix, e
   non affermata per non violare la regola "solo informazioni concrete".

**Correzione applicata**: `ansible/templates/dnsmasq/forge-dnsmasq.service.j2`
— rimosse tutte le direttive `Protect*`/`Restrict*`/
`MemoryDenyWriteExecute`/`LockPersonality`/`SystemCallArchitectures`
tranne `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`;
aggiunto commento che documenta la bisezione e perché le altre restano
deliberatamente fuori.

**Verifica**: configurazione finale (capability + `NoNewPrivileges` +
`ProtectSystem`/`ProtectHome`/`PrivateTmp`) applicata manualmente
sull'host e confermata: `systemctl status` -> `active (running)`,
`ss -Hlnup` mostra sia `virbr-forge:67` sia `192.168.250.1:69` in
ascolto.

**Nota operativa**: durante la diagnosi, un test manuale con `capsh`/
`strace` ha lasciato un processo `dnsmasq` residuo (PID 216707) che
teneva occupate le porte 67/69 fuori dal controllo di systemd
(`systemctl stop` non lo terminava) — causa di un falso negativo in un
test successivo. Terminato manualmente con `kill -9`. Non un bug del
repo, un artefatto della sessione di debug.

**Commit**: `643c30d`.

**Verifica finale tramite la pipeline reale** (non solo il test manuale
sull'host): pull del fix, `make lint` -> `EXIT_CODE=0` (146 file,
profilo `production`, nessun errore/warning proprio — solo i soliti due
warning attesi su `vault.yml` non decifrabile in questo contesto), poi
`make deploy-pxe` -> `EXIT_CODE=0`:

    ==========================================================
     PXE services ready
    ==========================================================
     DHCP/DNS/TFTP : forge-dnsmasq on virbr-forge
     Boot server   : http://192.168.250.1:8080
     Entry point   : http://192.168.250.1:8080/boot/boot.ipxe

     Per-host dispatch (what each MAC will receive on its next boot):
       poc-ubuntu-01    http://192.168.250.1:8080/state/52-54-00-25-00-21.ipxe
       poc-windows-01   http://192.168.250.1:8080/state/52-54-00-25-00-22.ipxe

    PLAY RECAP: ok=38  changed=3  failed=0  skipped=8

**Nota**: `make lint` sull'host richiede l'attivazione esplicita di
`.venv` (`. .venv/bin/activate`) — senza, `yamllint` non è sul `PATH` e
il target fallisce con `Error 127`. Non un bug: l'ambiente venv esiste
già (creato da `bootstrap.sh`), semplicemente non attivo per default in
una nuova sessione SSH non interattiva.

## Bug 18 — dnsmasq droppa il proprio UID a "nobody" e rifiuta i file root-owned in TFTP secure mode

**Sintomo**: dopo il bug 17, `make deploy-pxe` passava (`EXIT_CODE=0`,
DHCP e TFTP entrambi in ascolto), ma al reset di `poc-ubuntu-01` per
farla ripartire in PXE, il log reale mostrava una nuova, diversa,
`Permission denied`:

    dnsmasq-tftp[...]: cannot access /srv/forge-ai/tftp/ipxe.efi: Permission denied

nonostante il file fosse `-rw-r--r-- root root` (0644, leggibile da
chiunque) e ogni directory del percorso `0755 root:root` — verificato
con `namei -l`, non assunto.

**Diagnosi**:

1. Un `cat` diretto dello stesso file, eseguito con lo stesso identico
   `CapabilityBoundingSet` ristretto della unit reale (sostituendo
   temporaneamente `ExecStart` con `/bin/cat ...` nella stessa unit),
   **riesce** — quindi non è un vero diniego DAC/kernel a livello di
   permessi sul file.
2. `strace` sul vero binario `dnsmasq` (questa volta senza le direttive
   `Protect*` di mezzo, altrimenti bloccano `ptrace` da sole) durante
   una GET TFTP reale (`curl tftp://192.168.250.1/ipxe.efi`) mostra:

       geteuid() = 65534

   dnsmasq non gira più a UID 0: una volta che il proprio `capset()`
   interno riesce (bug 15), dnsmasq droppa **volontariamente** il
   proprio UID effettivo a `nobody` (65534), ritenendo sufficienti le
   ambient capabilities per continuare a servire le porte privilegiate.
   `tftp-secure` poi confronta l'owner del file (root, UID 0, come
   distribuito da questo ruolo) con l'UID *effettivo di dnsmasq stesso*
   (ora 65534) — non con i bit di permesso del file — e rifiuta ogni
   file per mismatch di ownership, riportando lo stesso testo
   "Permission denied" di un vero errore del kernel.

**Correzione applicata**: `ansible/templates/dnsmasq/provisioning.conf.j2`
— aggiunte `user=root` e `group=root` esplicite, per impedire il drop
automatico e mantenere dnsmasq all'UID con cui systemd lo ha già
avviato (`User=root` in `forge-dnsmasq.service.j2`), coerente con il
modello di hardening realmente in uso (capability ristrette via
`CapabilityBoundingSet`, non un cambio di UID).

**Verifica**: stesso test (`user=root`/`group=root` aggiunti a mano al
file di config reale, unit di test senza `Protect*`) -> `geteuid()`
resta `0`, e la GET TFTP reale riesce:

    dnsmasq-tftp[...]: sent /srv/forge-ai/tftp/ipxe.efi to 192.168.250.1

file scaricato, 1043968 byte, dimensione identica all'originale.

**Commit**: `ad66502`.

**Verifica finale tramite la pipeline reale e un boot vero**: `git
pull` sull'host, `make lint` -> `EXIT_CODE=0`, `make deploy-pxe` ->
`EXIT_CODE=0`, poi `virsh reset poc-ubuntu-01` per far ripartire la VM
da firmware. Log reale di dnsmasq:

    dnsmasq-tftp[...]: sent /srv/forge-ai/tftp/ipxe.efi to 192.168.250.21
    dnsmasq-tftp[...]: sent /srv/forge-ai/tftp/ipxe.efi to 192.168.250.21

e subito dopo, nel log di nginx (`boot-access.log`):

    GET /boot/boot.ipxe HTTP/1.1" 200 2923 "-" "iPXE/1.21.1+git-20220113.fbbdc3926-0ubuntu2"

Il firmware PXE ha scaricato `ipxe.efi` via TFTP, l'ha eseguito, e iPXE
ha proseguito da solo scaricando lo script di boot via HTTP — primo
chainload iPXE riuscito su questo host, catena PXE/TFTP/HTTP boot
completa e funzionante end-to-end.

## Bug 19 — `echo` con un divisore di trattini interpretato da iPXE come opzione sconosciuta

**Sintomo**: nonostante il bug 18 risolto, `poc-ubuntu-01` continuava a
rifare da capo l'intera sequenza DHCP -> TFTP -> `boot.ipxe` ogni 1-2
minuti circa, senza **mai** arrivare a richiedere lo script di dispatch
per-host (`GET /state/<mac>.ipxe`, mai comparso nel log nginx con lo
user-agent reale di iPXE) né a postare l'evento `ipxe-start` su
`/api/log` (mai comparso nella cronologia dello stato). La console
seriale (`virsh console`) non mostrava assolutamente nulla, nemmeno
durante un'intera finestra di 45s a cavallo di un reset fresco — non
un bug, ma una caratteristica di questa build OVMF/iPXE (il testo che
l'utente aveva visto in precedenza veniva probabilmente dal framebuffer,
non dalla seriale).

**Diagnosi (visibilità reale, non log indiretti)**: usato
`virsh screenshot <dominio> file.ppm` (cattura il framebuffer via
libvirt, nessun client VNC necessario) con una sequenza di scatti a
3/6/10/15s dopo un reset fresco. Il quarto scatto (10s) mostra l'errore
letterale sullo schermo:

    ==========...
    FORGE-AI GitOps provisioning -- environment poc
    ==========...
    MAC : 52:54:00:25:00:21
    IP : 192.168.250.21
    Platform : efi Arch: x86_64
    Boot server: http://192.168.250.1:8080
    Unrecognised option "-----------------------------------------------------------------------------"
    Usage:
      echo [-n|--n] [...]
    See https://ipxe.org/cmd/echo for further information
    Could not boot image: Invalid argument (https://ipxe.org/1c162282)
    No more network devices

`ansible/templates/ipxe/boot.ipxe.j2` usa due stili di divisore: righe
di `=` (che funzionano) e una riga di `-` (`echo
---------------------------------------------------------------`).
L'`echo` di iPXE analizza un `-` iniziale come flag di opzione (la sua
sintassi è `echo [-n|--n] [...]`) — una riga di soli trattini non è un
flag riconosciuto, l'intero script si interrompe senza alcun fallback
(nessun `||` su queste `echo` semplici), iPXE segnala "No more network
devices" e restituisce il controllo al firmware, che esaurisce anche
l'opzione disco (vuoto) e cade nella UEFI Shell — esattamente lo stato
in cui la VM era bloccata da ore.

**Correzione applicata**: `ansible/templates/ipxe/boot.ipxe.j2` — il
divisore di trattini sostituito con lo stesso stile a `=` già usato
altrove nello script, più un commento che spiega il comportamento di
`echo` di iPXE per evitare che la stessa svista si ripeta altrove.

**Nota**: nessun'altra occorrenza di `echo` seguito da un divisore a
trattini trovata negli altri template `.ipxe.j2` del repository
(verificato con una ricerca mirata, non assunto).

## Bug 20 — `params`/`param`/`##params` non supportati da questo build di iPXE

**Sintomo**: dopo il bug 19, il divisore ora funziona e lo script arriva
a stampare il banner (confermato via screenshot), ma si interrompe
subito dopo con un nuovo errore letterale sullo schermo:

    params: command not found
    Could not boot image: Exec format error (https://ipxe.org/2e022081)
    No more network devices

**Diagnosi**: `boot.ipxe.j2` usava `params` / `param mac ...` / `param
event ...` seguiti da `imgfetch --name ipxe-start ${log-url}##params`
per notificare il servizio di stato che iPXE è partito. Questo build
Ubuntu di iPXE (`1.21.1+git-20220113.fbbdc3926-0ubuntu2`, lo stesso
usato per `ipxe.efi`/`undionly.kpxe`) **non include affatto** la
feature "forms POST" (`params`/`param`/`##params`) — non un errore di
sintassi, il comando `params` stesso non esiste in questo binario.

Verificato **prima di correggere** (non assunto) leggendo l'handler
reale lato server in `compose/state-service/app.py`, funzione
`do_GET`:

    # iPXE reports progress with GET because imgfetch cannot POST.
    if path == "/api/log":
        LOG.info("ipxe event: %s", urlparse(self.path).query or "(no query)")
        self._send(HTTPStatus.OK, b"#!ipxe\nexit 0\n")
        return

Il servizio si aspetta **già** una GET con query string — il commento
nel codice lo dice esplicitamente. `params`/`##params` non era mai il
meccanismo giusto per raggiungerlo su questo build; una GET con
query string costruita a mano è esattamente quello che il server
prevede.

**Correzione applicata**: `ansible/templates/ipxe/boot.ipxe.j2` — il
blocco `params`/`param`/`imgfetch ##params` sostituito con un singolo
`imgfetch` la cui URL include la query string costruita direttamente
(`${log-url}?mac=${net0/mac}&event=ipxe-start&platform=${platform}&arch=${buildarch}`),
senza usare `params`/`param` in alcuna forma.

**Verifica e traguardo raggiunto**: dopo il fix, `virsh screenshot`
mostra la sequenza completa riuscire per la prima volta:

    Requesting provisioning state: http://192.168.250.1:8080/state/52-54-00-25-00-21.ipxe ... ok
    [state] poc-ubuntu-01: state=installing attempt=2/3
    [state] chaining the ubuntu-server installer
    http://192.168.250.1:8080/boot/host-52-54-00-25-00-21-install.ipxe ... ok
    http://192.168.250.1:8080/ubuntu/casper/vmlinuz ... ok
    http://192.168.250.1:8080/ubuntu/casper/initrd ... ok
    EFI stub: Loaded initrd from command line option

seguito da un secondo screenshot che mostra il **kernel Linux reale in
boot** (dmesg: driver SATA/USB/virtio-gpu, VLAN, RAID6...) — prima
riuscita end-to-end dell'intera catena DHCP -> TFTP -> iPXE -> kernel
-> Linux su questo host.

**Problema minore rimasto, non bloccante**: l'`imgfetch` del solo
evento di log `ipxe-start` fallisce ancora (`Could not start download:
Operation not supported`), gestito correttamente dal fallback `||
echo [warn] ... continuing` già presente nello script — non impedisce
il proseguimento del boot. Non approfondito ulteriormente: cosmetico
(perdita di un singolo evento di telemetria), non blocca
l'installazione. Da rivisitare se si vuole una telemetria completa.

**Commit**: `4117d49`.

## Bug 21 — 4096 MB RAM insufficiente per l'autoinstall `url=` di casper (ISO da 3.3 GB)

**Sintomo**: dopo i bug 19-20, il kernel Linux boota davvero e casper
inizia a scaricare l'ISO (`GET /iso/... "Wget"` nel log nginx), ma il
download si ferma **sempre** a 1918705422 byte (~1.79 GB) su 3303444480
byte totali (~3.3 GB), senza errori visibili e senza altre richieste
successive. Tre screenshot consecutivi (`virsh screenshot`), a diversi
minuti di distanza, mostrano il **framebuffer identico bit-per-bit**,
fermo al messaggio kernel `8021q: adding VLAN 0 to HW filter on device
eth0` (timestamp kernel 7.919543s).

**Diagnosi**: prima ipotesi (RAM esaurita in questo momento) scartata
con una verifica reale — `virsh dommemstat poc-ubuntu-01` mostra `unused
3830524` (KiB), quasi tutti i 4096 MB liberi in quel momento, non un
OOM in corso. Verificato invece se la VM sta eseguendo codice: tre
letture di `cpu.time` da `virsh domstats --cpu-total` a 2s di distanza
mostrano un incremento minimo (~1% di CPU) — la VM è viva a livello di
hypervisor (non crashata) ma **bloccata**, non sta facendo lavoro
utile.

Il taglio esatto e ripetibile a ~1.8 GB, ben al di sotto della RAM
totale disponibile (4 GB) ma coerente con un'area di staging
RAM-backed (tmpfs) dimensionata come frazione della RAM totale da
casper per il metodo di installazione `url=` (l'intera ISO va
scaricata in un'area temporanea in RAM prima che qualunque disco venga
partizionato), è il segnale più forte: con soli 4096 MB configurati,
non c'è spazio sufficiente per un'ISO da 3.3 GB più l'ambiente live
stesso.

**Grado di certezza**: il meccanismo esatto (nome/dimensione del tmpfs
usato da casper) **non è stato confermato via shell nel guest** — la
VM era bloccata, senza accesso interattivo. L'evidenza (byte esatti del
taglio, CPU quasi ferma, nessun ulteriore errore/richiesta) è coerente
con questa spiegazione ma resta un'inferenza, non una conferma diretta;
segnalato esplicitamente come tale invece di affermarlo come fatto
accertato.

**Correzione applicata**: `memory_mb` di `poc-ubuntu-01` portato da
4096 a 8192 in `config/poc.yml` (locale all'host, non in git) e nel
template di esempio `config/poc.example.yml` (in git, per non far
ripetere lo stesso problema a chi clona il repo). `vm_lifecycle`'s
"Redefine domains whose XML changed" già gestisce esattamente questo
caso (un cambio di `memory_mb` che deve raggiungere un dominio libvirt
già esistente) — nessuna modifica di codice necessaria, solo al
config.
