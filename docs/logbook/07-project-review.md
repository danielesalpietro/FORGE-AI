# 07 — Esecuzione del Project review (#5)

Piano: `docs/PROJECT-REVIEW.md`. Issue principale #5, sub-issue #6-#9.

## 2026-08-30 — Fase 0.1: consolidamento (#6)

- **Commit mancante recuperato**: le modifiche della migrazione
  CD-ROM (ipotesi 4) e del retry-loop erano state sincronizzate
  sull'outer host via pscp ma mai committate in git — trovate come
  9 file modificati nel working tree locale al momento di aprire la
  PR. Committate come `3a381c7` (già verificate lint/pytest durante
  la sessione precedente). Lezione: il doppio canale
  "pscp per testare subito + git per la storia" richiede un
  `git status` di controllo a fine giro, non solo a inizio.
- **PR**: esisteva già la draft #1 (dal 2026-08-27, pre-hardware).
  Aggiornata con l'esito della campagna e marcata ready for review;
  la motivazione del draft ("mai esercitato su hardware reale") non
  sussiste più.
- **Issue #2** aggiornata: sezione Fase 6 Windows (bug 24-31 risolti,
  bug 32 → #8), pipeline residua → #9, rimando a #5.
- **Snapshot ESXi**: `windows-chain-bug24-31-cdrom-delivery` (id 4)
  su `forge-poc-host-2`. VM id **8** verificato con
  `vim-cmd vmsvc/getallvms` prima di agire (il logbook 02 riportava
  vmid 7 per la creazione: lo stato reale vince sul documento).
  Snapshot senza memoria a VM accesa (crash-consistent, come i
  checkpoint precedenti).
- **Bug motd** (rendering senza fact): `ansible_default_ipv4.address
  | default(...)` non protegge quando è il dict stesso a essere
  indefinito — sotto StrictUndefined l'accesso all'attributo esplode
  prima che il default si applichi. Fix nel template (default sul
  dict prima dell'attributo) + aggiunto a `GLOBAL_TEMPLATES` nel
  rendering test. Esito: **205/205 pytest verdi e `make validate`
  passa per intero per la prima volta nella campagna** (commit
  `55a71e2`).
- **sudo NOPASSWD** per `dsalpietro` sull'outer host: valutazione
  favorevole (attrito `--ask-become-pass` documentato più volte;
  in un'occasione la password è comparsa in `ps aux` per un
  `echo | sudo -S` mal costruito; VM dedicata su segmento isolato).
  L'installazione del drop-in sudoers è una modifica di sicurezza
  che il classificatore dell'ambiente di automazione blocca
  correttamente: consegnata come comando pronto nel commento di
  chiusura di #6, da eseguire manualmente.

**Aggiornamento**: Daniele ha eseguito il comando NOPASSWD sull'host.
L'errore finale di `rm` era un difetto del comando suggerito (il file
in `/tmp` apparteneva a root dopo `sudo tee`, serviva `sudo rm`), ma
la catena si era rotta dopo l'`install`: il drop-in era già attivo.
Verificato dal vivo (`sudo -n true` → OK, drop-in `-r--r-----` in
`/etc/sudoers.d/`), residuo in `/tmp` ripulito. Da questo momento i
playbook non interattivi non richiedono più `--ask-become-pass`.

Stato: **Fase 0.1 chiusa, 5/5 task** (#6 chiusa). Prossima: Fase 0.3
punto 1 (volume NTFS nel diskpart, il test da minuti che può chiudere
il bug 32) e/o Fase 0.2 su decisione dell'operatore.

## 2026-08-30 — Fase 0.3 (#8): bug 32 root-causato e risolto

Percorso della diagnosi, in ordine, ogni passo su evidenza reale:

1. **Ipotesi "volume NTFS scratch mancante" falsificata**: aggiunti
   `create partition primary` + `format ntfs quick` + `assign` allo
   script diskpart; tutto riuscito lato disco, ma setup.exe fallisce
   identico e C: resta completamente vuoto — Setup muore prima di
   toccare qualunque disco.
2. **Svolta strumentale**: lanciando `I:\sources\setup.exe` (il
   binario reale) invece dello stub `I:\setup.exe`, per la prima
   volta in tutta la campagna compaiono un messaggio d'errore
   esplicito ("Windows could not apply the Windows PE bootstrap
   setting specified in the unattend answer file") e, soprattutto,
   **setupact.log/setuperr.log in X:\Windows\Panther**. Lo stub
   inghiotte dialoghi e log; d'ora in poi si lancia sempre il
   binario diretto (stessa scelta di MDT).
3. **setuperr.log, prova regina**: cinque errori CSI `E_INVALIDARG`
   su `node name = PathAndCredentials, name in handler = 0`, chiusi
   da `IBS Failed applying WinPE bootstrap unattend settings with
   status 0x80070057`. Il blocco DriverPaths dell'answer file è
   rigettato al parsing.
4. **Iterazione rapida con `virsh change-media`**: varianti
   dell'answer file costruite sull'host (genisoimage, secondi) e
   scambiate a caldo sul CD-ROM senza riavvii. La variante di
   controllo senza DriverPaths sposta l'errore a `0x8007007E`
   ERROR_MOD_NOT_FOUND — e la spiegazione arriva dal punto 5.
5. **Verifica dell'ambiente**: nel boot dell'immagine WinPE "pura"
   (indice 1, scelta del fix 28) `X:\sources` contiene **0 file**:
   niente runtime di Setup. Il "name in handler = 0" e il
   MOD_NOT_FOUND sono la stessa cosa vista da due angoli: setup.exe
   stava girando in un ambiente monco.
6. **Fix architetturale (bug 28+32 risolti insieme)**: si torna a
   bootare l'immagine "Setup" (indice 2, runtime completo) e
   startnet.cmd ci gira comunque grazie a un **winpeshl.ini
   iniettato via wimboot** — il meccanismo documentato: winpeshl.exe
   senza ini lancia X:\sources\setup.exe (ecco perché il bug 28
   "saltava" startnet); con l'ini esegue ciò che dice l'ini. Stesso
   pattern delle boot image MDT. Nuovo template
   `windows/winpeshl.ini.j2`, staging per host, imgfetch in iPXE,
   test aggiornati.
7. **Insidia di deployment scoperta nel primo test**: gli script
   iPXE per-host sono renderizzati da `ipxe_menu` (deploy-pxe /
   provision), non da `prepare-windows-media` — il primo boot di
   verifica usava lo script vecchio senza l'imgfetch di
   winpeshl.ini (Setup partito con l'auto-lancio di default, GUI
   moderna e errore `0x80070057 - 0x40030`). Dopo `make deploy-pxe`:
   **forge-ai.log presente su X:\ = startnet.cmd eseguito dentro
   l'immagine Setup** — fix winpeshl confermato sul reale.
8. **PathAndCredentials rigettato anche col runtime completo**:
   stesso E_INVALIDARG a runtime pieno → il blocco è genuinamente
   non supportato da questo engine (Server 2025 26100.32230, il
   nuovo setup 24H2), non un artefatto di handler mancanti.
9. **Prova finale**: variante senza DriverPaths, boot pulito
   automatico end-to-end → **"Installing Windows Server / Copying
   Windows Server files ✓ / Getting files ready (15%→36%...)"** — la
   prima installazione Windows completamente automatica mai
   raggiunta dalla pipeline. (Run di controllo ancora in corso al
   momento della scrittura.)
10. **Sostituto per i driver nell'OS installato** (senza DriverPaths
    l'OS non riceverebbe NetKVM → specialize senza rete → stallo
    tardivo): `setup.exe /InstallDrivers` (supportato da WinPE da
    24H2) contro una cartella piatta `forge-install-drivers` che
    `windows_media` ora stagia nella share virtio; startnet mappa la
    share su J: e passa il path stile-locale, evitando l'UNC.
    Answer file ripulito dal blocco, test aggiornati
    (`test_no_driver_paths_block_survives`,
    `test_startnet_passes_installdrivers`).

Nota di colore metodologico: il commento XML che spiegava la
rimozione di DriverPaths conteneva a sua volta un `--` letterale —
**quinta occorrenza** dello stesso errore autoinflitto nella
campagna, stavolta beccata dai rendering test in pochi minuti anziché
da un boot fallito su hardware.

Issue collegate aperte su richiesta di Daniele durante la sessione:
#10 (runner self-hosted per la non-regressione hardware, sub-issue di
#5) e #11-#14 (lifecycle Dev→Staging→Prod, issue autonoma con tre
sub-issue).

## 2026-08-30 — Esito del run di controllo (variante B) e bug 33

**Esito del run di controllo** (answer file senza DriverPaths,
consegnato via CD-ROM, boot pulito automatico): la fase 1
dell'installazione è arrivata fino in fondo — "Copying Windows Server
files ✓" e "Getting files ready" osservata dal 15% al 73% e oltre —
e la macchina **ha riavviato da sola** a fase completata. Primo run
nella storia del progetto in cui Windows Setup completa la fase WinPE
in modo completamente non presidiato.

**Bug 33 — il riavvio di metà installazione veniva reinterpretato
come nuovo tentativo di install, distruggendo il disco appena
scritto.** Colto DAL VIVO: al riavvio la VM è tornata in PXE (il boot
order resta network-first durante il provisioning, by design) con lo
stato ancora "installing", e il dispatch ha servito di nuovo
l'installer come "attempt 2" (evento nella history alle 07:55:55) —
il cui diskpart avrebbe ripulito il disco con l'installazione a metà.
VM fermata a mano in extremis. La differenza strutturale col percorso
Ubuntu: autoinstall POSTa "installed" PRIMA di riavviare, Windows lo
riporta solo nel pass specialize, DOPO il primo boot dal disco — un
boot PXE durante "installing" è quindi la normale continuazione per
Windows, un fallimento per Linux.

**Fix** (`compose/state-service/app.py`): per un host con
`os_family == windows` in stato `installing` e almeno un dispatch già
avvenuto, un boot PXE riceve boot-local ("mid-install reboot,
continuing from local disk"), con contatore limitato
(`FORGE_WINDOWS_MID_INSTALL_LOCAL_BOOTS`, default 3) così
un'installazione davvero morta ricade comunque sul retry/park. Il
controllo sta PRIMA della guardia sul limite tentativi (il riavvio
dell'ultimo tentativo consentito deve comunque bootare locale). La
fixture di test del registry è stata allineata al registry reale
(che porta `os_family`); quattro test nuovi coprono boot-local,
limite, invarianza del comportamento Linux e reset del contatore.
Container `forge-state` ricostruito e riavviato col fix. 211/211
test verdi.

**Fix minori nel giro**: il task di staging della cartella driver
piatta girava sotto `sh` (`set -o pipefail` → "Illegal option") per
un `executable: /bin/bash` dimenticato — la stessa convenzione
stabilita al bug 24, beccata dal run reale; e la QUINTA occorrenza
del `--` letterale in un commento XML (nel commento che spiegava la
rimozione di DriverPaths!), beccata stavolta dai rendering test in
minuti.

## 2026-08-30 — Run definitivo end-to-end (in corso)

Precondizioni verificate una per una prima del lancio: cartella
`forge-install-drivers` con 6 .inf sulla share virtio; startnet.cmd
servito con `/InstallDrivers`; Autounattend servito senza blocco
DriverPaths (l'unica occorrenza è il commento esplicativo); ISO
unattend reale ripristinata nella config persistente del dominio
(dopo i change-media di test); winmedia riavviata preventivamente e
verificata; state-service col fix bug 33 attivo.

Lanciato `make provision-windows` completo. Catena attesa: PXE →
winpeshl.ini → startnet (driver, rete, SMB, diskpart) →
`sources\setup.exe /InstallDrivers J:\forge-install-drivers` → fase 1
→ riavvio → **boot local via fix 33** → specialize (driver presenti →
rete → download SetupComplete → stato `installed`) → SetupComplete →
`configuring` → WinRM. Esito nel prossimo aggiornamento.

Issue aggiuntive aperte su richiesta di Daniele durante l'attesa:
#15-#19 e #24-#25 (asset-inventory dims.db, 6 fasi), #20-#23
(secrets-vault + CA interna), #26-#29 (control plane multi-nodo con
API e CLI `dims`).

## 2026-08-30 — Bug 34 e 35, colti entrambi dal vivo sul run definitivo

**Bug 34 — la fetch di validazione del deployment contava come
dispatch reale.** Al primo tentativo del run definitivo lo stato
mostrava `install_local_boots=1` dopo 10 minuti — impossibile per un
riavvio vero. La history lo ha inchiodato: il "first dispatch" delle
08:10:24 era la GET di validazione di `ipxe_menu` ("Prove the
dispatch path end to end"), non la VM; il boot genuino della VM
(08:19:49) è arrivato come secondo dispatch ed è stato classificato
dal fix 33 come riavvio di metà installazione → boot local su disco
vuoto → menu firmware TianoCore. Effetto collaterale storico scoperto
retroattivamente: quella fetch **bruciava in silenzio un tentativo di
install a ogni deployment fin dall'inizio** (ecco perché gli install
Ubuntu partivano regolarmente da "attempt 2"). Fix: `dispatch()`
guadagna `probe=True` (stessa decisione, zero mutazioni), l'endpoint
accetta `?probe=1`, e il task di validazione lo usa. Test dedicato:
un probe non tocca stato, tentativi né contatore local-boots.
Container ricostruito. 212/212 test verdi.

**Bug 35 — `/InstallDrivers` appartiene al nuovo entry point, non a
`sources\setup.exe`.** Al riavvio pulito post-fix-34, dialogo
esplicito: "An unknown command-line option [/InstallDrivers] was
specified" dal binario legacy. Riletta la sezione esatta della doc
Microsoft salvata: l'opzione è "from WinPE since 24H2", ricorsiva —
ma implementata dal setup moderno (lo stub alla radice del media).
La vecchia ragione per evitare lo stub (inghiottiva dialoghi e log
durante la diagnosi del bug 32) è decaduta con il passaggio
all'immagine Setup completa, dove il logging Panther funziona con
qualunque entry point. Fix: startnet lancia
`%FORGE_SRC%\setup.exe /InstallDrivers %FORGE_DRV%\forge-install-drivers`.

**Esito immediato**: al ciclo successivo (stato resettato, dispatch
genuino: attempts=1, local_boots=0) la UI moderna a schermo intero è
comparsa per la prima volta nel flusso automatico — **"Installing
Windows Server — Your PC will restart several times. This might take
a while. 13% complete"** — installazione non presidiata in corso con
i driver in consegna via /InstallDrivers. Prossimi checkpoint: i
riavvii intermedi devono ricevere `dispatch-local-mid-install`
(fix 33), poi specialize → `installed` → SetupComplete →
`configuring` → WinRM.

## 2026-08-30 — Il fix 33 convalidato dal vivo; bug 36 (aperto): dopo l'exit di iPXE il firmware non arriva a Windows Boot Manager

L'installazione non presidiata è progredita 13% → 29% → 78%, poi il
primo riavvio di metà installazione (10:24:45Z). La state API ha
risposto esattamente come da progetto: `dispatch-local-mid-install
1/3`, attempts fermo a 1 — **il fix del bug 33 funziona dal vivo**.

Ma il boot successivo non è arrivato a Windows: la VM è ricaduta nel
menu firmware TianoCore invece di caricare il boot manager appena
scritto da Setup. Il menu Boot Manager del firmware (screenshot
s0336/s0337) elenca, nell'ordine: UEFI PXEv4, PXEv6, HTTPv4, HTTPv6,
**Windows Boot Manager** (Device Path
`HD(1,GPT,5F3B208F-…)\EFI\Microsoft\Boot\bootmgfw.efi`), UEFI Misc
Device, EFI Internal Shell, UEFI QEMU DVD-ROM. Quindi Setup HA
scritto la ESP e la voce NVRAM; il problema è la catena di
continuazione: dopo che lo script `boot local` di iPXE fa `exit`,
BdsDxe avrebbe dovuto scorrere le voci successive fino a WBM, e
invece si è fermato al menu.

**Bug 36, per ora aperto e non diagnosticato con certezza.** Due
ipotesi in campo, non ancora discriminate:

1. Comportamento reale di OVMF: con `-boot` via fw_cfg, la
   rielaborazione di BootOrder (QemuBootOrderLib) potrebbe non
   riprendere la sequenza automatica dopo il ritorno dell'app iPXE.
2. Interferenza dei miei stessi `send-key` di diagnostica: attorno al
   riavvio stavo ancora interagendo con la console; un tasto arrivato
   durante il prompt del bootmenu (timeout 3 s nel dominio) può aver
   interrotto la sequenza e aperto il menu.

Il prossimo riavvio di metà installazione è l'esperimento
discriminante: **osservazione puramente passiva, zero tasti inviati
al guest**. Se auto-avvia WBM, il bug 36 si declassa a interferenza
dell'operatore; se ricade nel menu, è reale e va corretto (candidati
già analizzati: hd-first per i domini Windows sfruttando il
fall-through naturale del disco vuoto verso PXE; `bcdedit
/set {fwbootmgr}`; flip anticipato del boot order).

Nel frattempo: selezionata manualmente la voce Windows Boot Manager
(4×DOWN + ENTER, evidenziazione verificata su screenshot prima
dell'invio). Windows è ripartito da disco — **"Installing 42% — Your
computer may restart a few times"** — la fase offline del setup
moderno prosegue. Stato: `installing`, attempts=1, local_boots=1.

## 2026-08-30 — Bug 36 confermato dall'esperimento passivo; bug 37 (specialize) diagnosticato dai log Panther; doppio fix e rilancio

**Bug 36 confermato reale.** Il secondo riavvio di metà installazione
(10:49:59Z, `dispatch-local-mid-install 2/3`) è avvenuto in
osservazione puramente passiva — nessun tasto inviato da nessuno — e
la VM è ricaduta comunque nel menu firmware. Non era interferenza
dell'operatore. Causa trovata nella documentazione iPXE (discussion
789): `exit` senza status ritorna EFI_SUCCESS, e BdsDxe interpreta
"boot option riuscita" → smette di scorrere la boot order e mostra il
menu. `exit 1` ritorna un errore, che è ciò che fa proseguire il
firmware alla voce successiva (hd/WBM). Fix applicato in
`script_local()` (state service), `boot.ipxe.j2` e `menu.ipxe.j2` —
gli ultimi due erano lo stesso bug latente mai innescato.

**Bug 37 — i comandi specialize da 400+ caratteri invalidano l'intero
answer file.** Al boot manuale su WBM l'installazione è proseguita
(42% offline) ma è morta con il dialogo "The computer restarted
unexpectedly" (windeploy 0x1f). Shift+F10 sul dialogo →
`C:\Windows\Panther\UnattendGC\setuperr.log` e
`C:\Windows\Panther\setuperr.log` letti a schermo: il validatore SMI
della fase specialize boccia i `RunSynchronousCommand/Path` degli
Order 3, 4 e 5 ("Value is invalid", dump da 846 byte ≈ 423 caratteri
UTF-16 — i one-liner curl-con-fallback-powershell), dichiara
`unattend.xml is not a valid unattended Setup answer file` e
l'installazione abortisce. Gli Order 1 e 2, corti, passavano. Nota di
metodo: era la prima volta in assoluto che il flusso raggiungeva la
fase specialize, coerente col fatto che il bug emerga solo ora. Il
timestamp nel log (03:48:33, fuso del guest) colloca l'errore già al
PRIMO boot locale: il riavvio 2/3 era il reboot d'errore di windeploy.

Fix: un solo RunSynchronousCommand corto (~200 caratteri renderizzati)
che scarica ed esegue `specialize.cmd`, servito per-host accanto a
SetupComplete.cmd; tutta la logica (mkdir, staging dei due script,
callback installed, spedizione del log al boot server) vive nello
script. Chiusura con `exit /b 0`: un download transitoriamente fallito
non deve abortire l'intera installazione — senza script il playbook va
in timeout con diagnosi precisa, che è meglio di un half-install non
avviabile. Tre test nuovi: guardia di lunghezza (<259) su tutti i
Path, contenuto del wrapper, contenuto di specialize.cmd. **215/215
verdi.**

Decisione concordata con Daniele (che spingeva, ragionevolmente, per
un test pulito diretto su ESXi visti i due giorni di grind): il bug 37
è nel file di risposta, non nell'ambiente — su ESXi sarebbe fallito
identico. Quindi: fix + UN rilancio nested; se fallisce su qualcosa di
nuovo, pivot immediato alla fase 0.2 (issue #7) con l'answer file
ormai corretto.

Rilancio (commit ff6977b): container state ricostruito (probe
conferma `exit 1` nello script servito), winmedia riavviata
preventivamente (share verificate), VM distrutta, `make
provision-windows` in background. Esito al prossimo aggiornamento.
