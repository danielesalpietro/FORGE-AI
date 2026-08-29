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
