# Checklist di non regressione — VM outer su ESXi (creazione + autoinstall)

Ogni voce qui è nata da un problema reale incontrato in
`docs/logbook/02-vm-outer-creazione-e-tentativi-autoinstall.md` la notte
del 2026-08-28, durante la creazione manuale via SSH/`vim-cmd` di
`forge-poc-host`/`forge-poc-host-2`. Da ripassare prima di ogni
reinstallazione dell'outer host, o dopo un cambiamento importante che
richiede di rifare la VM da zero — non solo la prima volta.

Non sostituisce `handoff_setup_esxi.md` (il piano completo): è un
controllo mirato sui punti che hanno già causato perdite di tempo.

## Trasferimento di file grandi (ISO) verso un datastore ESXi

- [ ] Per file di alcuni GB o più, **non usare `scp`/`pscp`** come primo
      tentativo: su questa rete entrambi sono caduti a metà trasferimento
      (errori diversi — `Software caused connection abort` con `pscp`,
      `Connection reset by peer` con `scp` nativo — stessa sostanza),
      anche con keepalive SSH attivi. Causa esatta non isolata (non è un
      timeout di shell ESXi: `UserVars/ESXiShellTimeOut` e
      `UserVars/ESXiShellInteractiveTimeOut` erano entrambi `0`).
- [ ] Usare invece l'upload HTTPS diretto al datastore (lo stesso
      meccanismo del browser datastore del client vSphere):

      ```bash
      curl -k -T <file-locale> \
        "https://<host-esxi>/folder/<sottocartella>/<nome-file>?dcPath=ha-datacenter&dsName=<datastore>" \
        -u "root:<password>"
      ```

      Verificato più stabile (~35MB/s sostenuti) e completato senza
      errori dove due tentativi via SCP erano falliti.
- [ ] **Verificare sempre la dimensione del file arrivato con `ls -la`
      sul datastore** prima di considerare un upload riuscito — un task
      in background può essere segnalato "completato con successo"
      anche quando il trasferimento reale si è interrotto a metà.

## Prerequisiti locali, prima di iniziare

- [ ] **Docker Desktop attivo** (`docker info` risponde) — serve per
      costruire la ISO seed con `genisoimage`/`xorriso` in un container
      Alpine/Ubuntu usa-e-getta.
- [ ] **PuTTY `plink.exe`/`pscp.exe` disponibili** — usati per SSH/upload
      non interattivi verso ESXi via password (niente `sshpass` su
      Windows).
- [ ] **`govc.exe`** (github.com/vmware/govmomi/releases) — per inviare
      tasti virtuali alla console via API quando serve un intervento a
      tastiera scriptabile (es. parametro kernel `autoinstall`), invece
      di dipendere da un client console con possibili problemi di focus.
- [ ] **Password root ESXi** letta da un file locale fuori dal
      repository, mai passata in chiaro su una riga di comando che
      finisce nella cronologia della shell.

## Prima di creare qualunque cosa sull'host

- [ ] **Non fidarsi dei nomi di datastore scritti in un piano/handoff**:
      verificarli freschi con `esxcli storage filesystem list`. Il piano
      originale di questo progetto descriveva un NVMe da 180GB e un pool
      da 5TB che non esistono su questo host — i datastore reali sono
      volumi VMFS-6 da ~1-2TB ciascuno.
- [ ] **Verificare quali datastore ospitano già VM di produzione**
      (`vim-cmd vmsvc/getallvms`) e scegliere un datastore libero per la
      nuova VM, per non competere con VM esistenti — su questo host:
      `GestioneAffitti_DR` (DR backup Veeam) e `VMware vCenter Server 8`
      sono VM di produzione, da non toccare.

## Scrittura del `.vmx` a mano

- [ ] Su `virtualHW.version = "19"` con controller `pvscsi`/`vmxnet3`,
      includere sempre il blocco `pciBridge0.present` +
      `pciBridge4`-`pciBridge7` (`virtualDev = "pcieRootPort"`,
      `functions = "8"`) — senza, il power-on fallisce con
      `No PCIe slot available for SCSI0`.
- [ ] La ISO seed NoCloud va sullo **stesso canale IDE** dell'ISO di
      boot ufficiale (es. `ide1:1` accanto a `ide1:0`), **non** su un
      canale diverso (es. `ide0:0`) — un CD-ROM non avviabile su un
      canale IDE separato può far fallire il boot con
      `No operating system was found`, a seconda di come il BIOS
      enumera i device.
- [ ] Per aggiungere/modificare un dispositivo su una VM già registrata:
      **spegnere la VM**, sovrascrivere il `.vmx` sul datastore,
      **verificare col grep che il file sul datastore contenga davvero
      la modifica** prima di riaccendere. Non fidarsi di
      `vim-cmd vmsvc/reload` su una VM accesa: in questa sessione ha
      silenziosamente scartato un dispositivo appena aggiunto.

## Virtualizzazione nidificata + GPU passthrough insieme (`.vmx` a mano)

La webGUI di ESXi **blocca** la combinazione VHV (nested virt) + PCI
passthrough: la configurazione va fatta a mano nel `.vmx` (VM spenta,
poi verifica col grep come sopra). Fatto con successo il 2026-08-30 su
`forge-poc-host` (GTX 1060 6GB + kvm-ok verde nella guest); questi
sono i valori **letti dal file reale** funzionante:

- [ ] `vhv.enable = "TRUE"` — virtualizzazione nidificata
      (`kvm-ok` verde nella guest).
- [ ] `vhv.allowPassthru = "TRUE"` — **la chiave che sblocca la
      coesistenza** di VHV e passthrough; senza, la webGUI rifiuta la
      configurazione.
- [ ] `pciPassthru.use64bitMMIO = "TRUE"` — indirizzamento MMIO a 64
      bit per i BAR della GPU.
- [ ] `pciPassthru.64bitMMIOSizeGB = "6"` — dimensionare **almeno pari
      alla VRAM** della GPU (6 verificato funzionante con la GP106 da
      6 GB; un valore più alto, es. 16, è la scelta prudente se la RAM
      MMIO non scarseggia).
- [ ] I device passthrough veri e propri (`pciPassthru0.*` con
      `id`/`deviceId`/`vendorId`/`systemId`/`present`) si possono far
      generare alla webGUI *prima* di aggiungere a mano le chiavi
      vhv/MMIO; per la GTX 1060 vanno passate **entrambe le funzioni**
      (VGA `0x1c03` e audio `0x10f1`).
- [ ] **⚠ Ogni successiva modifica dalla webGUI RIMUOVE
      silenziosamente `vhv.enable = "TRUE"`** — Broadcom non vuole la
      combinazione, e la GUI la "corregge" senza avvisare né fallire.
      Quindi, su una VM con GPU condivisa + nested VT-x: dopo
      QUALUNQUE modifica di configurazione fatta dalla GUI,
      ri-verificare il `.vmx` sul datastore
      (`grep -i vhv <vm>.vmx` → devono esserci ancora `vhv.enable` e
      `vhv.allowPassthru`) e nella guest (`kvm-ok`) prima di fidarsi.
      Il sintomo a valle è subdolo: la VM parte normalmente ma
      `/dev/kvm` sparisce e le VM annidate cadono in emulazione TCG
      (lentissima) o non partono.

## File `user-data` (autoinstall)

- [ ] **Non riusare il dump letterale** di
      `/var/log/installer/autoinstall-user-data` (sezione
      `storage.config` con partizioni/offset/dimensioni in byte) da
      un'altra installazione, nemmeno su un disco nominalmente identico
      — causa un crash Subiquity in `apply_autoinstall_config` (crash
      confermato due volte in questa sessione, con due ISO seed
      diverse). Usare invece lo shorthand ufficiale:

      ```yaml
      storage:
        layout:
          name: lvm
          match:
            size: smallest
          sizing-policy: all
      ```

- [ ] Senza `sizing-policy: all`, Subiquity lascia la logical volume di
      root più piccola della partizione LVM che la contiene (verificato:
      partizione da 58G, LV di root da soli 29G, ~29G liberi ma non
      assegnati nel volume group) — stesso comportamento visto anche
      nell'installazione manuale di riferimento. Con `sizing-policy: all`
      l'installer assegna tutto lo spazio disponibile alla root LV.

- [ ] Verificare la struttura della ISO seed **prima** di caricarla:
      `isoinfo -d` / `blkid -p` devono mostrare `Volume id: cidata` (o
      `CIDATA`) e `user-data`/`meta-data` in root.
- [ ] Senza il parametro kernel `autoinstall` sulla riga di boot,
      Subiquity si ferma su un prompt di conferma
      (`Continue with autoinstall? (yes|no)`) prima di toccare il disco
      — non è un errore, ma non è nemmeno "non presidiato" senza
      risposta. Per un'installazione davvero unattended, iniettare il
      parametro (console + `govc vm.keystrokes`, o accettare
      un'unica conferma manuale).

## Verifica del boot/installazione — non fidarsi dello stato "Powered on"

- [ ] `vim-cmd vmsvc/power.getstate` risponde `Powered on` **anche
      quando il BIOS non ha trovato un sistema operativo e si è
      fermato** (`[msg.Backdoor.OsNotFound]` in `vmware.log`). Sempre
      incrociare con il log, non fidarsi del solo power state.
- [ ] Conferma di installazione riuscita: `vim-cmd vmsvc/get.guest`
      deve mostrare `toolsRunningStatus = "guestToolsRunning"`,
      `hostName` e `ipAddress` valorizzati — segno che il sistema
      installato si è avviato (non l'ambiente live).
- [ ] Verifica finale reale: **login SSH riuscito**, non solo
      raggiungibilità della porta 22. Controllare da dentro la VM:
      - `lsblk`: il disco dati (es. `sdb`) deve risultare **senza
        partizioni** — l'installer non deve averlo toccato.
      - `free -h`: la RAM libera deve essere vicina al totale assegnato
        (riserva memoria applicata), swap quasi non utilizzato.
      - `df -h /`: dimensione coerente con il layout LVM guidato atteso.

## Cose da NON fare (confermate durante questa sessione)

- [ ] Non modificare il firewall Windows dell'operatore per aprire una
      porta verso la VM — è una modifica a un'impostazione di sicurezza
      di sistema, vietata indipendentemente da chi la richiede. Se serve
      consegna via rete del seed e la porta è bloccata, passare alla
      consegna via CD-ROM locale invece di aprire il firewall.
  - Uso di `sudo -S` con la password passata via `echo ... | sudo -S`
      su un host remoto: bloccato dal classificatore di sicurezza della
      sessione — non aggirarlo, chiedere all'utente un'alternativa
      (NOPASSWD mirato, o recupero manuale del dato).
- [ ] Non commitare mai un hash di password (nemmeno crypt(3)/SHA-512)
      in un commit o in un logbook del repository — tenerlo solo in
      file locali fuori dal repository.
