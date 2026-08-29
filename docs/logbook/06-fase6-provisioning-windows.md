# 06 — Fase 6: `make provision-windows` (poc-windows-01)

## Contesto

Dopo il successo completo di `poc-ubuntu-01` (bug 15-23, vedi
`docs/logbook/05-fase6-provisioning-target-vm.md`), primo tentativo di
provisioning di `poc-windows-01` (Windows Server 2025 Standard).

## Preparazione — trasferimento dell'ISO

L'utente ricordava di aver già scaricato l'ISO di Windows Server 2025
Evaluation sull'host ESXi. Verificato prima di assumere: `find
/vmfs/volumes -maxdepth 3 -iname '*win*'` conferma
`windows-server-2025-eval-en-us.iso` (8152356864 byte) sul datastore
`datastore1`, mai trasferita su `forge-poc-host-2` (solo l'ISO Ubuntu
era in `/srv/forge-ai/iso/`).

Trasferita con lo stesso metodo HTTPS già collaudato in questa sessione
per i trasferimenti di file grandi (scp/pscp si erano già dimostrati
inaffidabili su questa rete) — stavolta nel verso opposto: l'host
outer stesso ha fatto un `curl` diretto contro l'endpoint del
datastore ESXi:

    curl -sk -u "root:<password>" \
      'https://192.168.1.133/folder/ISOs/windows-server-2025-eval-en-us.iso?dcPath=ha-datacenter&dsName=datastore1' \
      -o /srv/forge-ai/iso/windows-server-2025-eval-en-us.iso

Verificato con `-I` (HEAD) prima di lanciare il download completo:
`content-length: 8152356864`, poi confermato a trasferimento concluso
che la dimensione finale corrispondeva esattamente.

`config/poc.yml` aggiornato (locale all'host, gitignored):
`media.windows.iso_path`, `iso_sha256` (calcolato da `make
windows-images`, pinnato per rilevare una ISO sostituita). `make
windows-images` ha confermato che `image_name: "Windows Server 2025
SERVERSTANDARD"` già presente nel file corrispondeva esattamente
all'edizione `[2]` reale dentro `install.wim` — nessuna correzione
necessaria lì.

`make lint` e `make validate-config` puliti prima di procedere.

## Bug 24 — `wimlib-imagex info --xml` stampa UTF-16, Ansible richiede UTF-8

**Sintomo**: `make provision-windows` fallisce al primo vero task
Windows-specifico:

    TASK [windows_media : Read the image metadata from the installation image]
    [ERROR]: Task failed: Refusing to deserialize an invalid UTF8 string value:
              'utf-8' codec can't encode characters in position 0-1: surrogates not allowed

**Diagnosi**: `ansible/roles/windows_media/tasks/inspect-wim.yml` esegue
`wimlib-imagex info {{ image }} --xml` con `ansible.builtin.command`,
poi ripulisce i byte nulli dall'output con `regex_replace('\x00', '')`
prima di estrarre gli indici con una regex — il codice era già
consapevole che l'output fosse "UTF-16 con BOM" (commento esistente),
ma il `regex_replace` non ha mai la possibilità di girare: il modulo
`command` di Ansible cattura lo stdout e lo fa transitare per il
proprio protocollo JSON interno tra il sottoprocesso del modulo e il
processo principale, che richiede UTF-8 valido. Byte UTF-16 decodificati
come UTF-8 producono "surrogati soli" (lone surrogates), non
rappresentabili in UTF-8 — la deserializzazione fallisce prima ancora
di restituire il risultato al playbook.

Verificato sull'host reale, non assunto:

    wimlib-imagex info install.wim --xml | file -
      -> /dev/stdin: Unicode text, UTF-16, little-endian text ...
    wimlib-imagex info install.wim --xml | head -c 60 | xxd
      -> 00000000: fffe 3c00 5700 4900 4d00 3e00 ...   (BOM FF FE, poi ogni carattere ASCII seguito da 0x00)

Controllato anche il percorso di fallback (`wimlib-imagex info` senza
`--xml`, usato solo se il parsing XML non trova nulla): quello **è**
già UTF-8 (`file -` conferma), non ha lo stesso bug — non toccato.

**Correzione applicata**: `ansible/roles/windows_media/tasks/inspect-wim.yml`
— il task cambiato da `ansible.builtin.command` a `ansible.builtin.shell`
(serve una pipe) con `wimlib-imagex info {{ image | quote }} --xml |
iconv -f UTF-16 -t UTF-8`, convertendo a UTF-8 valido **prima** che
Ansible catturi lo stdout. Il successivo `regex_replace('\x00', '')`
diventato superfluo (non ci sono più byte nulli intercalati dopo la
conversione) ed è stato rimosso.

**Verifica**: `wimlib-imagex info install.wim --xml | iconv -f UTF-16
-t UTF-8 | head -c 200` produce XML leggibile e valido
(`<WIM><TOTALBYTES>7255895157</TOTALBYTES><IMAGE INDEX="1">...`).

Ri-lanciato `make provision-windows`: superato correttamente il punto
del bug 24, edizione risolta (`index 2: "Windows Server 2025
SERVERSTANDARD"`), estrazione ISO saltata correttamente (già fatta al
tentativo precedente).

## Nota operativa — stallo di rete durante il download di virtio-win.iso

**Non un bug del repository.** Il task "Download the VirtIO driver ISO"
(fetch di `virtio-win-0.1.266.iso`, 691 MB, da `fedorapeople.org`) si è
fermato dopo aver scritto ~86 MB, restando fermo per 4+ minuti pur con
la connessione TCP ancora in stato `ESTAB`.

**Diagnosi**: confermato con `/proc/<pid>/io` che `wchar` (byte scritti
su disco) era rimasto **identico** (86069598) su due controlli a 5
minuti di distanza — non un download lento, un download fermo per
davvero. `ss -tpi` sulla connessione ha mostrato `rcv_ooopack:6374`
(pacchetti ricevuti fuori ordine) e nessun byte ricevuto negli ultimi
264 secondi (`lastrcv`) nonostante lo stato ancora `ESTAB` — coerente
con un segmento perso mai ritrasmesso su quella specifica sessione TCP,
un'anomalia di rete verso quel server/percorso, non un problema di
raggiungibilità (un semplice `curl -I` verso lo stesso URL era stato
confermato funzionante pochi minuti prima con HTTP 200 in meno di un
secondo).

**Azione**: terminato il processo bloccato (`pkill -9` sul playbook,
poi `kill -9` sui figli `AnsiballZ_get_url.py` rimasti orfani —
uccidere il processo padre non termina automaticamente i figli già
biforcati). Nessun file parziale lasciato nella destinazione (il
modulo `get_url` di Ansible scrive su un file temporaneo prima del
rename finale, quindi un fallimento a metà non lascia un file
troncato al suo posto). Ripetuto `make provision-windows` da capo con
una connessione TCP nuova.

Il secondo tentativo (con una connessione pulita) ha scaricato
virtio-win.iso senza intoppi (verificato con `/proc/<pid>/io`: byte
scritti in crescita costante, non più fermi) ed è arrivato molto più
avanti — fino al bug 25.

## Bug 25 — verifica dell'iniezione driver cerca backslash, wimlib-imagex stampa slash

**Sintomo**: `make provision-windows` fallisce per la prima volta su un
task Windows-specifico più a fondo del bug 24:

    TASK [windows_winpe : Assert the driver injection succeeded]
    [ERROR]: Task failed: Action failed: No .inf files found under
              \Windows\System32\drivers\forge inside
              /srv/forge-ai/http/windows/boot-forge.wim.

**Diagnosi**: prima ipotesi (i path sorgente `driver_paths` in ordine
sbagliato, es. `viostor/2k25/amd64` invece di `amd64/2k25/viostor`)
scartata verificando la struttura reale della ISO virtio-win estratta:
`find .../virtio/viostor -maxdepth 4` conferma che
`viostor/2k25/amd64/viostor.inf` esiste davvero (la ISO contiene
**entrambe** le strutture, indicizzata sia per driver che per
architettura). L'output del task "Show what was staged" conferma
inoltre che lo staging **ha funzionato**: "collected 6 driver
directories", con `balloon.inf`, `netkvm.inf`, `viostor.inf` ecc.
elencati per nome.

Verificato quindi **dove sono finiti davvero** i file dentro il WIM,
invece di continuare a ipotizzare, con lo stesso comando che il
messaggio di errore stesso suggerisce:

    wimlib-imagex dir boot-forge.wim 2 | grep -i forge
      -> /Windows/System32/drivers/forge/viostor.inf   (e altri 5 .inf)

**I file ci sono, al posto giusto** — ma con **slash normali**
(`/Windows/...`), non i backslash che il pattern di verifica si
aspettava (`\\Windows\\System32\\drivers\\forge\\.*\.inf`, scritto
per un path in stile Windows). `wimlib-imagex dir` stampa sempre con
slash Unix, indipendentemente dal fatto che il contenuto sia
un'immagine Windows. Confermato isolando i due pattern uno per uno
contro lo stesso output reale: quello con backslash trova 0
corrispondenze, quello con slash normali ne trova 6 — la stessa
identica lista di file.

**L'iniezione dei driver funzionava correttamente fin dall'inizio**:
il bug era solo nella regex della verifica, un falso negativo che
interrompeva la pipeline nonostante il lavoro reale fosse già
riuscito.

**Correzione applicata**: `ansible/roles/windows_winpe/tasks/inject-drivers.yml`
— il pattern grep della "Verify the drivers are present inside the
image" cambiato da `'\\Windows\\System32\\drivers\\forge\\.*\.inf'` a
`'/Windows/System32/drivers/forge/.*\.inf'`. Nessun'altra occorrenza
di `wimlib-imagex dir` nel repository (verificato con una ricerca
mirata) da correggere allo stesso modo.

**Nota**: il file `boot-forge.wim` prodotto da questo run fallito
contiene già i driver correttamente iniettati (verificato a mano) — al
prossimo tentativo la copia/iniezione verrà saltata perché il file
esiste già (`when: forge_wim_copied is changed`), ma la verifica ora
corretta troverà i driver reali già presenti e passerà.

## Nota operativa — il servizio `winmedia` (SMB export) non era in esecuzione

**Non un bug.** Superato il bug 25, il playbook si è fermato con un
messaggio guida chiaro:

    The Windows media SMB export at //192.168.250.1 is not answering.
    WinPE cannot reach install.wim without it...

    Start it:
      docker compose ... --profile windows up -d winmedia

`Makefile:50` calcola dinamicamente `WINDOWS_PROFILE` da
`media.windows.iso_path` in `config/poc.yml` e lo aggiunge alle
invocazioni di `docker compose up`. Il controllo plane era già stato
avviato con `make bootstrap`/`make up` **prima** che l'ISO Windows
fosse configurata in questa sessione, quindi al momento di quel primo
`up` il profilo `windows` non veniva ancora richiesto e `winmedia` non
è mai partito. Avviato manualmente con il comando suggerito
dall'errore stesso; confermato raggiungibile con
`smbclient -N -L //192.168.250.1` (condivisioni `winmedia` e `virtio`
entrambe presenti).

## Bug 27 — `qxl` video model non supportato da questa build QEMU

**Sintomo**: dopo aver superato bug 24, 25 e avviato `winmedia`,
`make provision-windows` arriva per la prima volta a definire il
dominio libvirt per `poc-windows-01` e fallisce subito:

    msg: 'libvirtError: unsupported configuration: domain configuration
          does not support video model ''qxl'''

**Diagnosi**: `ansible/templates/libvirt/domain.xml.j2` sceglie il
modello video in base al sistema operativo:
`{{ 'qxl' if host.os_family == 'windows' else 'virtio' }}`. `qxl`
richiede QEMU compilato con supporto SPICE, che questa build non ha.
Verificato senza assumere, interrogando le capacità reali dell'host:

    virsh domcapabilities --machine q35 --arch x86_64 --virttype kvm
      -> <video supported='yes'><enum name='modelType'>
           vga, cirrus, vmvga, virtio, none, bochs, ramfb
         </enum></video>

`qxl` non compare nell'elenco. Nessun problema per `poc-ubuntu-01`,
che usa già `virtio` (nell'elenco supportato) — il problema riguardava
solo il ramo Windows del condizionale.

**Correzione applicata**: `ansible/templates/libvirt/domain.xml.j2` —
`qxl` sostituito con `bochs` per i guest Windows: un framebuffer
"stupido" che QEMU emula senza bisogno di alcun driver guest, la
scelta convenzionale per un guest Windows senza SPICE, così Setup/WinPE
hanno comunque un display prima che carichi qualunque driver GPU.
Linux resta su `virtio` (già collaudato su `poc-ubuntu-01`). Nessun
altro riferimento a `qxl` nel repository (verificato con una ricerca
mirata).

**Errore autoinflitto (mio, non un bug di sessioni precedenti)**: il
primo tentativo di applicare questo fix ha inserito un commento
esplicativo nel template XML contenente doppi trattini letterali
(`... does not have -- libvirt refuses ...`) — non validi dentro un
commento XML, esattamente lo stesso errore già capitato due volte in
sessioni precedenti su questo stesso file (vedi
`docs/ESXI-OUTER-VM-CHECKLIST.md`). `vm_lifecycle : Render the domain
XML` ha fallito la validazione (`msg: failed to validate`, `parser
error : Double hyphen within comment`) dopo che il controllo del disco
qcow2 (231s, genuinamente attivo per tutto il tempo, confermato con
`ps aux`/CPU time in crescita costante — non uno stallo) era finalmente
terminato. Corretto sostituendo i doppi trattini con due punti nel
commento, senza toccare la logica.

Con questi fix, `poc-windows-01` ha completato per la prima volta
l'intera catena di boot (PXE → iPXE → wimboot → boot.wim → GUI grafica
di "Windows Server Setup", visibile via `virsh screenshot`) — un
traguardo importante, ma la GUI si è fermata su "A media driver your
computer needs is missing" (nessun disco visibile), nonostante bug 25
avesse già confermato i driver VirtIO correttamente presenti nel WIM.

## Sessione successiva — diagnosi interattiva via console (Shift+F10)

Ripresa della diagnosi da uno snapshot dello stato descritto sopra.
Navigazione GUI del selettore cartelle (via `virsh send-key`, nessun
supporto mouse nativo in virsh) per cercare manualmente la cartella
`drivers` inconcludente — non compariva nell'albero alfabetico tra
"DiagTrack" ed "en-US", verosimilmente perché il picker filtra le
cartelle con l'attributo "System" di Windows, non perché i file
mancassero. Abbandonato questo percorso come inaffidabile.

Pivot verso **Shift+F10**, la scorciatoia standard di Windows Setup per
aprire un prompt dei comandi reale durante l'installazione — molto più
diretto della navigazione GUI alla cieca. Da lì, lettura diretta di
`X:\forge-ai.log`: **il file non esisteva affatto**
(`The system cannot find the file specified`), nonostante lo script
`startnet.cmd` lo scriva come primissima riga. `dir X:\Windows\System32\startnet.cmd`
confermava che il file iniettato via wimboot era davvero quello di
FORGE-AI (contenuto corretto, non un residuo di stock) — quindi non un
problema di iniezione, ma di **esecuzione**: lo script non era mai
partito.

## Bug 28 — i driver vengono iniettati nell'immagine "Setup" del boot.wim, che salta interamente startnet.cmd

**Diagnosi**: `dir X:\` mostrava `setup.exe` alla radice della RAM disk
X: (99.904 byte, datato come l'intero albero `Windows`) — il
`setup.exe` **nativo** dell'immagine, non quello di FORGE-AI su `I:\`
(condivisione di rete). `X:\Windows\System32\winpeshl.ini` **non
esisteva affatto**. Un `boot.wim` di installazione Windows contiene due
immagini — indice 1 "Microsoft Windows PE", indice 2 "Microsoft Windows
Setup" — e `wimlib-imagex info` sul file reale confermava
`Boot Index: 2` nei metadati del WIM: è questo campo (non il file BCD,
copiato verbatim dall'ISO) a dire a wimboot quale immagine montare come
X:\ all'avvio. L'immagine "Setup" ha un proprio bootstrap che lancia
`X:\sources\setup.exe` direttamente, **bypassando interamente**
`winpeshl.ini`/`startnet.cmd` — comportamento Microsoft nativo, non
configurabile senza intervenire sul WIM stesso. `inject-drivers.yml`
(bug preesistente, mai verificato end-to-end prima d'ora) iniettava
deliberatamente i driver proprio nell'indice 2, con un commento che
assumeva "l'immagine Setup è quella che avvia l'installer, quindi è lì
che vanno i driver" — assunzione plausibile ma sbagliata: è l'immagine
PE (indice 1) quella il cui percorso di avvio esegue
`startnet.cmd`, e il nostro stesso `startnet.cmd` già lancia
`setup.exe` come ultimo passo (pattern standard per iniettare driver
VirtIO in un Setup Windows via WinPE).

**Correzione applicata**: `ansible/roles/windows_winpe/tasks/inject-drivers.yml`
— il pattern di ricerca dell'indice cambiato da "il nome contiene
Setup" a "il nome NON contiene Setup" (seleziona l'indice 1), default
da `'2'` a `'1'`. Aggiunto un nuovo task subito dopo l'iniezione,
`Set the WinPE image as the WIM's boot index`, che esegue
`wimlib-imagex info <wim> <indice> --boot` (sintassi verificata con
`wimlib-imagex info --help` prima di scriverla) per impostare
esplicitamente l'indice 1 come Boot Index del WIM — senza questo,
wimboot continuerebbe a montare l'indice 2 indipendentemente da quale
indice ha ricevuto i driver.

**Verifica**: rigenerato il media (`make prepare-windows-media -e
winpe_force_rebuild=true`), `poc-windows-01` resettata. Al riavvio, la
finestra della console mostra per la prima volta
`X:\windows\system32\cmd.exe - startnet.cmd` con i passi 1-4 in
esecuzione (driver VirtIO caricati via `drvload`, tutti "Successfully
loaded" per `viostor.inf`, `vioscsi.inf`, `netkvm.inf`, `balloon.inf`,
`vioser.inf`; rete inizializzata; mount SMB riuscito; **DiskPart ha
rilevato Disk 0, lo ha ripulito e convertito con successo in GPT** — il
sintomo originale, "Install driver to show hardware", è risolto: il
driver di storage funziona.

## Nota operativa — `make prepare-windows-media`/`provision-windows` non girava non-interattivo senza `--ask-become-pass`

**Non un bug del repository.** Un tentativo di rigenerare il media in
background è fallito subito: `sudo: a password is required`.
Verificato (non assunto) che `dsalpietro` non ha NOPASSWD in
`/etc/sudoers`/`/etc/sudoers.d/` su questo host, e che
`ansible_become_password` non è definito in nessun vault — il
funzionamento nelle sessioni precedenti dipendeva da una password sudo
già "calda" nella cache del terminale interattivo di quel momento, non
riproducibile in un nuovo processo SSH non interattivo. Corretto
aggiungendo `--ask-become-pass` a `ANSIBLE_ARGS` e fornendo la password
tramite lo stesso stdin già usato per `sudo -S` in questa sessione.

**Nota operativa collegata**: trovati due processi `ansible-playbook
provision-windows.yml` orfani (avviati ~30 minuti prima, residuo di un
comando lanciato prima di un compattamento della conversazione),
ancora vivi e potenzialmente in corsa contro la stessa VM/domain XML
che si stava diagnosticando. Ripuliti con `kill -9` prima di procedere
— stesso pattern già documentato nella Fase 6 di Ubuntu (bug
15-23): usare sempre `run_in_background: true` per comandi remoti
lunghi, mai un timeout locale breve.

## Bug 29 — `7z x` non preserva/imposta il bit di esecuzione Unix, Samba nega l'esecuzione di setup.exe

**Sintomo**: risolto il bug 28, `startnet.cmd` arriva fino al passo
6/6 ma esce subito: `setup.exe returned control with errorlevel 5`.
Rilanciando lo stesso comando a mano da una console Shift+F10:
`I:\setup.exe /unattend:...` → **`Access is denied.`**, esplicito e
immediato.

**Diagnosi**: `compose/samba/smb.conf`, sezione `[winmedia]`, ha
`force user = nobody` — ogni accesso alla condivisione, qualunque
credenziale usi il client Windows, viene forzato all'utente Unix
`nobody` (uid 65534). Verificato sul filesystem reale (non assunto):

    ls -la /srv/forge-ai/http/windows/media/setup.exe
      -> -rw-r--r-- 1 root root 99896 ... setup.exe

Permessi `644`: leggibile da chiunque, **eseguibile da nessuno** —
`nobody` ricade nella classe "other", che non ha il bit `x`. Samba
mappa fedelmente questo bit Unix mancante in un diniego dell'accesso
"execute" lato Windows, anche se la lettura semplice (`type`,
`if exist`, che è quello che le verifiche precedenti dello script
usavano) funziona senza problemi — da qui il falso senso di "i file ci
sono e sono raggiungibili" fino al lancio effettivo.

**Causa radice**: `ansible/roles/windows_media/tasks/main.yml`, task
"Extract the Windows ISO" (`7z x`), non imposta permessi dopo
l'estrazione. ISO9660/UDF non tracciano un bit di esecuzione Unix, per
cui 7z estrae tutto con la modalità di default (644) — inclusi i file
`.exe`.

**Correzione applicata**: `ansible/roles/windows_media/tasks/main.yml`
— nuovo task "Fix executable permissions lost during extraction" subito
dopo l'estrazione (`when: forge_windows_extract is changed`):
`chmod -R a+rX` sull'intero albero estratto più un `find -type f -exec
chmod a+rx` su ogni file, senza distinguere per estensione (media di
sola lettura per un guest Windows, nessun rischio a marcare tutto
eseguibile lato Unix). Applicato anche direttamente sul filesystem reale
per sbloccare il test in corso senza dover ri-estrarre l'intera ISO
(`chmod -R a+rX` + `find ... -exec chmod a+rx`), poi verificato che il
fix nel playbook fosse equivalente prima di fidarsene per il run
successivo.

**Verifica**: `ls -la setup.exe` dopo il fix → `-rwxr-xr-x`. Rilanciato
`I:\setup.exe /unattend:...` dalla stessa console: nessun più "Access is
denied" — il permesso era davvero la causa di quello specifico
messaggio.

## Bug 30 — `Autounattend.xml` iniettato nel percorso convenzionale confligge con `/unattend:` esplicito

**Sintomo**: risolto il bug 29 (niente più "Access is denied" testuale),
`setup.exe /unattend:X:\Windows\System32\Autounattend.xml` continua a
uscire istantaneamente con lo stesso `errorlevel 5`, questa volta senza
alcun messaggio visibile e senza creare `setupact.log` (solo file di
telemetria in `X:\Windows\Panther\`, es. `windlp.state.xml`).
Lanciato **senza** `/unattend` (`I:\setup.exe` da solo): la GUI grafica
di Setup si apre normalmente — isolando il problema specificamente al
file di risposta o al suo percorso, non a setup.exe in generale.

**Diagnosi per eliminazione, non per ipotesi sul contenuto XML**: la
documentazione ufficiale Microsoft
(learn.microsoft.com/.../windows-setup-command-line-options) conferma
la sintassi `/Unattend:<answer_file>` corretta e non elenca `5` fra i
codici di uscita documentati di Setup (tutti gli altri sono valori
`0xC19...` tipo `MOSETUP_E_*`) — indizio che 5 sia ancora un
`ERROR_ACCESS_DENIED` Win32 grezzo, stavolta interno a Setup anziché a
`cmd.exe`. Testato per esclusione, con lo **stesso file, byte per
byte** (`cp` del file renderizzato reale, non ridigitato a mano):

1. Copiato l'`Autounattend.xml` reale (identico) sulla condivisione
   `winmedia` e referenziato come `I:\Autounattend-test.xml` →
   **`errorlevel 0`**, successo completo (compare persino la cartella
   di staging `NewOs` in Panther, prova di una fase di deployment
   avanzata).
2. Ricreato l'intero contenuto originale (tutti e 4 i pass, incluso
   `DriverPaths`) e ritestato via `I:\` → **`errorlevel 0`** ancora.
   Il contenuto XML, `DriverPaths` incluso, non è la causa.
3. Copiato **con `copy` locale** lo stesso file già iniettato da
   wimboot (`X:\Windows\System32\Autounattend.xml`, quello che fallisce)
   su un percorso diverso della stessa RAM disk (`X:\test.xml`),
   nessuna rete coinvolta → **`errorlevel 0`**, successo.

Il file è identico in tutti e quattro i casi (stessa dimensione, stesso
contenuto), l'unica variabile è il **percorso**. Windows Setup rileva
automaticamente `\Windows\System32\Autounattend.xml` come posizione
convenzionale del file di risposta — avere un file lì e passarlo
*anche* esplicitamente con `/unattend:` genera un conflitto (verosimilmente
Setup apre/elabora la propria copia auto-rilevata prima che il flag
esplicito venga onorato) che fa uscire `setup.exe` immediatamente con
errorlevel 5, prima ancora che venga scritto `setupact.log`.

**Correzione applicata**:
`ansible/templates/ipxe/host-windows-install.ipxe.j2` — l'argomento
cmdline passato a wimboot per l'iniezione del file di risposta cambiato
da `Autounattend.xml` a `forge-unattend.xml` (il nome sorgente sull'host
resta `Autounattend.xml`, cambia solo il nome con cui wimboot lo
inietta in `\Windows\System32\` dentro l'immagine). `ansible/templates/windows/startnet.cmd.j2`
— il flag `/unattend:` aggiornato di conseguenza a
`X:\Windows\System32\forge-unattend.xml`, evitando così il percorso
auto-rilevato.

**Correzione della correzione**: il primo tentativo di questo fix
cambiava solo l'ultimo token della riga `imgfetch` (il "cmdline"
passato all'immagine), lasciando `--name Autounattend.xml` invariato —
e un riavvio reale ha mostrato che è **`--name`**, non il token finale,
a determinare il nome con cui wimboot inietta il file
(`dir X:\Windows\System32\*.xml` sulla console mostrava ancora
`Autounattend.xml`, 14.355 byte, mai `forge-unattend.xml`). Con questo
mismatch, `startnet.cmd` puntava `/unattend:` a un file che non
esisteva affatto, e Setup mostrava una finestra di dialogo esplicita:
"The installation process was launched with an invalid command line
argument." Corretto cambiando anche `--name` in `forge-unattend.xml`
nello stesso task; verificato di nuovo sulla console che il file
iniettato ora si chiama davvero così.

## Bug 31 — `diskpart` fallisce su un disco lasciato offline/read-only da un tentativo precedente

**Sintomo**: in una sessione con molti tentativi di installazione
interrotti sullo stesso disco qcow2, `[4/6] diskpart` ha fallito con:

    Virtual Disk Service error: The operation is not allowed on a disk
    that is offline.

**Diagnosi**: lo script diskpart di `startnet.cmd.j2` faceva solo
`select disk 0` / `clean` / `convert gpt`, assumendo il disco sempre
online e scrivibile. Un disco che ha già visto un tentativo di
partizionamento/installazione precedente su questo stesso host può
tornare a un riavvio successivo con l'attributo "offline" o "readonly"
impostato — un comportamento Windows normale per i dischi con una
firma già nota — e in quello stato `clean` stesso si rifiuta di
partire.

**Correzione applicata**: `ansible/templates/windows/startnet.cmd.j2`
— aggiunti `online disk` e `attributes disk clear readonly` allo
script diskpart, prima di `clean`. Entrambi i comandi sono no-op
innocui su un disco già online e scrivibile, quindi non cambiano nulla
per il caso comune (primo tentativo, disco vergine).

**Verifica**: ri-renderizzato via `make prepare-windows-media`,
riavviata `poc-windows-01`: il log mostra ora "DiskPart successfully
onlined the selected disk." e "Disk attributes cleared successfully."
prima delle righe di clean/convert già viste in precedenza, ed è la
prima volta in questa sessione che il passo 4/6 supera un disco
precedentemente scritto senza intervento manuale.

## Nota operativa — la condivisione SMB `winmedia` smette di rispondere alla VM dopo molti reset ravvicinati

**Non ancora root-causata con certezza — segnalata come limite noto,
non corretta nel repository.** Dopo i fix di bug 28/29/30/31, diversi
riavvii consecutivi di `poc-windows-01` (via `virsh reset`/`destroy`+
`start`, decine di volte in questa sessione per isolare i bug sopra)
hanno mostrato `[3/6] net use` fallire di nuovo con `System error 53
... The network path was not found`, nonostante:

  - `ping 192.168.250.1` dalla console WinPE avesse sempre successo
    (0% loss);
  - `smbclient -N -L //192.168.250.1` dall'outer host avesse **sempre**
    avuto successo, in ogni momento in cui è stato controllato;
  - un riavvio del container `forge-winmedia`
    (`docker compose ... restart winmedia`) risolvesse il sintomo
    immediatamente — il tentativo di boot successivo montava la
    condivisione senza errori — ma il sintomo si ripresentava dopo
    altri reset ravvicinati della VM.

Ipotesi più plausibile, non confermata: i miei stessi `virsh
reset`/`destroy` ripetuti troncano la sessione TCP della VM verso
`smbd` in modo brusco (nessun logoff SMB pulito), e qualche stato
lato-server (una entry di lock, una voce di connection-tracking) resta
non ripulito abbastanza in fretta da bloccare il tentativo successivo.
`smbstatus` dentro il container, controllato durante un fallimento
attivo, non mostrava alcuna connessione dalla VM (192.168.250.22) — solo
una dall'host stesso — a indicare che il pacchetto SYN della VM non
arriva mai fino a `smbd`, non che `smbd` lo rifiuti esplicitamente.
Verificato che le regole iptables DNAT/FORWARD per la porta 445 esistono
e hanno contatori di pacchetti diversi da zero, ma non è stato
possibile catturare un pacchetto della VM in tempo reale per confermare
dove si perde esattamente.

**Non è un pattern realistico per un'installazione reale**: un
operatore che segue il flusso normale (`make provision-windows` una
volta, attesa dei 15-30 minuti) non genera mai decine di reset
ravvicinati sulla stessa VM nell'arco di un'ora come ha fatto questa
sessione diagnostica. Segnalato qui per completezza e per chi si
imbattesse nello stesso sintomo durante un debug intensivo: la
soluzione immediata è riavviare `winmedia` prima del tentativo
successivo.

Con `winmedia` appena riavviato e un solo reset manuale della VM (nessun
reset intermedio successivo), il tentativo 2/3 ha superato in sequenza
tutti i passi già corretti in questa sessione — `net use` riuscito al
primo colpo, diskpart con "DiskPart successfully onlined the selected
disk." + "Disk attributes cleared successfully." + clean + convert GPT
tutti riusciti — confermando bug 28, 29, 30 e 31 tutti risolti insieme
per la prima volta nello stesso avvio. `setup.exe` è stato raggiunto e
lanciato, ma è uscito con un nuovo codice non ancora visto:

    [error] setup.exe returned control with errorlevel -1047527137.

## Bug 32 (aperto, non risolto) — `setup.exe` esce con 0xC190011F dopo aver superato bug 28-31

**Non root-causato in questa sessione.** -1047527137 come intero a 32
bit con segno corrisponde a `0xC190011F` — nella famiglia di codici
`MOSETUP_E_*` documentata da Microsoft per il caricamento/validazione
del file di risposta ("Windows setup encountered an internal error
while loading or searching for an unattend answer file"), ma il valore
esatto non compare nella pagina ufficiale delle opzioni da riga di
comando consultata in questa sessione, e senza `setupact.log` (mai
scritto: `X:\Windows\Panther\` contiene solo i file di telemetria
`DlTel-Merge.etl`/`windlp.state.xml`, nessuna cartella `NewOs` questa
volta) non è stato possibile isolarne la causa esatta con evidenza
diretta come per i bug precedenti.

Elementi noti che lo distinguono dai bug già risolti:

  - non è più "invalid command line argument" (quel dialogo esplicito
    non è più comparso da quando `--name` è stato corretto insieme al
    token cmdline in bug 30) — il file di risposta viene trovato e
    almeno in parte elaborato;
  - non è più errorlevel 5 generico (bug 29/30 originali) né l'assenza
    di `NewOs` per un semplice fallimento di analisi XML immediato,
    dato che in un tentativo precedente **con lo stesso identico
    contenuto XML completo** (i quattro pass, letto via `I:\` invece
    che dal percorso iniettato da wimboot) Setup era arrivato fino alla
    fase di staging (`NewOs` presente) con successo;
  - è comparso **solo** nei tentativi successivi all'aggiunta di `online
    disk` / `attributes disk clear readonly` al passo diskpart (bug
    31) — non ancora confermato se le due cose siano causalmente
    collegate o una coincidenza dovuta al fatto che questi sono stati
    anche i primi tentativi ad arrivare a `setup.exe` con un disco già
    pulito da un run precedente.

**Ipotesi da verificare in una prossima sessione, non ancora testate:**

  1. Isolare di nuovo per eliminazione (come per bug 30) usando lo
     stesso trucco `I:\setup.exe /unattend:I:\<file>` sulla condivisione
     scrivibile lato host, questa volta con il file di risposta REALE
     completo (non quello minimale) per vedere se fallisce anche lì —
     se sì, il problema è nel contenuto o nello stato del disco, non
     nel percorso di iniezione; se no, punta di nuovo a qualcosa di
     specifico del percorso `X:\Windows\System32\forge-unattend.xml`.
  2. Provare `setup.exe /unattend:... /noreboot /emsport off` con
     logging esplicito, o cercare se questa build WinPE espone un modo
     di ottenere `setupact.log` prima del fallimento (es. un
     `/logpath` esplicito).
  3. Verificare se `online disk` + `attributes disk clear readonly`
     lasciano il disco in uno stato (es. stile MBR residuo, o una
     GPT header duplicata) che il `<DiskConfiguration>` di Setup non
     si aspetta, confrontando l'output di `diskpart` → `list disk` /
     `list partition` subito dopo il fix, prima di invocare `setup.exe`.
  4. (Suggerita da un consiglio esterno rivisto in questa sessione,
     non ancora testata.) Cambiare il meccanismo di consegna: invece
     di iniettare `Autounattend.xml` dentro il WIM via wimboot e
     passarlo con `/unattend:` esplicito, allegarlo come supporto
     virtuale separato (piccola ISO/floppy costruita da Ansible,
     seconda voce `<disk>` nel dominio libvirt, sullo stesso pattern
     già usato per `windows_attach_virtio_cdrom` in `domain.xml.j2`)
     e **rimuovere il flag `/unattend:` esplicito**, lasciando che
     Setup lo trovi da solo sul supporto allegato. Sposterebbe il file
     fuori dal percorso wimboot -- quello già responsabile dei bug 28
     e 30 -- ed eliminerebbe strutturalmente l'intera classe di
     conflitti rilevamento-automatico/flag-esplicito, non solo il caso
     già corretto.

## Stato finale di questa sessione

Bug 28, 29, 30 (e la sua correzione) e 31 tutti corretti e verificati
singolarmente con evidenza diretta su console reale, e per la prima
volta confermati funzionare **insieme** nello stesso avvio (tentativo
2/3, vedi sopra). Bug 32 resta aperto: `setup.exe` viene raggiunto e
lanciato correttamente ma esce con `0xC190011F` prima di scrivere
`setupact.log`, causa non ancora isolata. La condivisione SMB
`winmedia` resta un limite operativo noto sotto reset ravvicinati
ripetuti (vedi nota sopra), mitigato riavviando il container prima di
ogni nuovo tentativo pulito. Prossimo passo naturale: le tre ipotesi
elencate sopra per bug 32, a partire dalla n. 1 (il test di isolamento
più economico e già collaudato in questa sessione).
