# Handoff: validazione e2e su ESXi 8

Documento di lavoro, non parte della narrazione del PoC. Se lo stai leggendo
sei la sessione Claude con accesso alla rete dove vive l'host ESXi: questo
file è il tuo assegnamento completo. Nessun contesto precedente ti è stato
passato a parte questo file — leggilo tutto prima di eseguire il primo
comando.

Esiste un documento gemello, `handoff_setup.md`, scritto per una VM diversa
(una ZBook con VMware Workstation) che stanotte non era disponibile. Se
quella VM è tornata operativa e qualcuno sta già lavorando lì, i due
percorsi sono indipendenti: non serve coordinarli, ma se trovi un bug di
repository comune a entrambi, verifica prima con `git log` che non sia già
stato corretto nel frattempo.

## Obiettivo

Portare il PoC FORGE-AI a un'esecuzione end-to-end reale su una VM Ubuntu
Server 24.04 con virtualizzazione annidata, creata da zero su un host ESXi
8. A differenza dell'altro percorso, qui la VM non esiste ancora: la crei
tu, come primo passo.

Almeno il target Ubuntu deve arrivare a `ready`. Ogni problema che incontri
va risolto nel codice, quando è un bug del repository, o documentato con
causa e limite quando non lo è. Ogni fase va registrata in un logbook
secondo il formato più sotto.

## Accesso e credenziali — leggi prima di tutto

- Host ESXi: `192.168.1.133`, utente `root`.
- La password ti è stata data da Daniele fuori da questo documento. Non è
  scritta qui, e non deve mai finire in un commit, in un logbook, in
  un'Artifact, o in qualunque testo che lasci questa macchina. Se la devi
  passare a un comando non interattivo, scrivila in un file con permessi
  `0600` che il repository ignora già (`.gitignore` copre `.env` e simili
  — verifica prima di usarne uno nuovo), mai in chiaro sulla riga di
  comando dove finirebbe nella cronologia della shell.
- **Root su ESXi ha un raggio d'azione enorme**: tocca ogni macchina
  virtuale sull'host, i datastore, la rete. Resta confinato al ciclo di
  vita della VM che crei qui — non toccare altre VM, altri datastore, o
  la configurazione dell'host stesso al di fuori di quanto serve per
  questa VM.

## Cosa significa "fatto"

- Una VM Ubuntu Server 24.04 creata sull'host, con virtualizzazione
  annidata esposta e funzionante (`/dev/kvm` presente e scrivibile).
- `make validate` e `make lint` verdi sull'ospite.
- `./bootstrap/check-prerequisites.sh --verbose` in stato `READY`.
- Il control plane (`make bootstrap` o `./bootstrap/bootstrap.sh`) su e
  verificato: `make test-integration` e `make test-molecule` eseguiti e il
  loro esito — pass o fail — registrato per intero nel logbook. Non sono
  mai girati da nessuna parte prima d'ora.
- Il target `poc-ubuntu-01` installato via PXE, configurato, verificato
  con `make validate-deployment` e `make smoke-test`.
- La prova di idempotenza eseguita e il suo risultato riportato
  testualmente, non riassunto — è un'affermazione della pull request
  (<https://github.com/danielesalpietro/FORGE-AI/pull/1>) mai controllata
  su hardware reale.
- Drift detection e riconciliazione eseguiti almeno una volta.
- Ogni bug di repository trovato: corretto, testato, committato e
  pushato con un messaggio che spiega la causa, non solo il sintomo.
- Un logbook per fase, più un riepilogo finale.
- Il target Windows resta fuori scope finché Daniele non fornisce una ISO
  di Windows Server 2025 — non è più una questione di spazio disco, vedi
  sotto, solo di media non ancora disponibile.

## Le due impostazioni obbligatorie sulla VM

Uniche vere differenze rispetto a un'installazione su un ipervisore
qualsiasi: senza queste due, il resto del piano non parte o si comporta in
modo imprevedibile.

1. **Expose hardware-assisted virtualization to the guest OS**, nelle
   impostazioni CPU della VM. Senza, KVM dentro la VM annidata non
   funziona: è l'equivalente esatto della spunta "Virtualize Intel
   VT-x/EPT" di VMware Workstation. Su un host ESXi bare-metal non
   esiste l'incertezza che c'era con Hyper-V su Windows — questa
   impostazione basta da sola.

2. **Reserve all guest memory (All locked)**, nelle impostazioni Memory
   della VM. Senza, ESXi crea un file di swap (`.vswp`) sul datastore
   dimensionato sulla RAM assegnata non riservata — con l'host a 128 GB
   fisici non costa nulla riservarla tutta, ed elimina un consumo di
   spazio disco altrimenti silenzioso e imprevedibile.

## Specifica della VM

| Voce | Valore |
|---|---|
| Sistema | Ubuntu Server 24.04.x — non Desktop |
| vCPU | 8, dei 12 core / 24 thread disponibili sull'host |
| Memoria | 32 GB dei 128 fisici, con riserva completa (vedi sopra) |
| Disco di sistema | ~60 GB, sul datastore NVMe piccolo (quello con 180 GB liberi visti stanotte) |
| Disco dati | vedi sezione storage sotto — su un datastore diverso |
| Rete | una port group normale con uscita internet, non isolata |

Sistema e non Desktop: il PoC non ha interfaccia grafica, e ogni GB
risparmiato dall'ospite va ai target. Sul networking: la rete di
provisioning interna (192.168.250.0/24, DHCP e PXE) vive interamente
dentro la VM tramite libvirt e non tocca mai il vSwitch — la VM ha solo
bisogno di un indirizzo che esca su internet per scaricare pacchetti e
ISO, esattamente come il NAT su Workstation. Se esiste una policy di
segmentazione di rete più stretta su questo host, verificala prima di
procedere: questo documento assume che non ce ne sia una.

## Storage: due volumi, non uno

L'host ha un datastore NVMe piccolo (180 GB liberi, visto ieri sera) e un
pool più grande da circa 5 TB su un altro datastore. Il PoC non deve
scrivere sul disco di sistema della VM:

1. Crea un **secondo disco virtuale** per la VM, ritagliato dal pool da
   5 TB — non dal datastore NVMe piccolo. Una taglia comoda: 300-500 GB
   thin-provisioned. Identifica il nome esatto del datastore da 5 TB
   tramite il client (vista Storage) o, da SSH sull'host,
   `esxcli storage filesystem list`, e registralo nel logbook.

2. Dentro la VM, dopo il primo avvio:

   ```bash
   lsblk                              # conferma il nuovo disco, es. /dev/sdb
   sudo parted /dev/sdb --script mklabel gpt mkpart primary ext4 0% 100%
   sudo mkfs.ext4 /dev/sdb1
   sudo mkdir -p /srv
   UUID=$(sudo blkid -s UUID -o value /dev/sdb1)
   echo "UUID=$UUID  /srv  ext4  defaults  0  2" | sudo tee -a /etc/fstab
   sudo mount -a
   df -h /srv
   ```

   L'UUID in `/etc/fstab`, non il nome del device diretto: le lettere
   possono spostarsi, e un riavvio è già previsto più avanti in questo
   piano, per i gruppi `kvm`/`libvirt` — il mount deve sopravvivergli.

3. In `config/poc.yml`, dopo averlo creato da `config/poc.example.yml`:

   ```yaml
   storage:
     artifacts_dir: /srv/forge-ai
     libvirt_pool_path: /srv/forge-ai/images
   ```

   Entrambi sotto lo stesso mount: il controllo dei prerequisiti li
   somma come un unico requisito invece di due, ed è il ramo già testato
   del codice (vedi il bug numero 4 sotto per il perché questo controllo
   esiste nella forma attuale).

Con questo layout il conto torna largo: 120 GB richiesti dal PoC (entrambi
i target dichiarati, anche se Windows resta fuori scope per ora) più circa
20 GB di overhead della VM stessa, contro centinaia di GB reali
disponibili. Non c'è bisogno di restringere la configurazione al solo
target Ubuntu per motivi di spazio — se lo fai, è una scelta di
sequenziamento (più semplice verificare un target alla volta), non una
necessità aritmetica.

## Bug già trovati e corretti stanotte — non ripeterli

Quattro problemi reali sono già stati diagnosticati e risolti in questo
stesso branch. `git log --oneline -6` dopo il clone deve contenere questi
commit; se non li vedi, `git pull` prima di andare oltre.

1. **`libvirt-python` non compila senza `libvirt-dev`.** È pubblicato su
   PyPI solo come sorgente: la compilazione cerca `libvirt.pc` via
   `pkg-config` e senza header Python e compilatore fallisce con un
   errore che non nomina nessun pacchetto Debian. Corretto in `c8ed22e`
   aggiungendo `pkg-config`, `libvirt-dev`, `python3-dev`, `gcc` a
   `bootstrap/prepare-host.sh`.

2. **`ansible-playbook` non trovato durante `bootstrap.sh`.**
   `install-host` crea `ansible-playbook` dentro `.venv/`, ma
   `bootstrap.sh` e tre script in `scripts/` chiamavano il comando nudo,
   contando su un `PATH` attivato a mano. Corretto in `427a1f5` con
   `FORGE_ANSIBLE_PLAYBOOK` in `bootstrap/lib/common.sh`.

3. **L'appartenenza ai gruppi `kvm`/`libvirt` non si propaga con un
   logout parziale.** In una sessione bridge Remote Control, "uscire e
   rientrare" a parole non basta se il processo che esegue i comandi non
   viene davvero rigenerato. **Il fix è un riavvio della VM**, non
   `newgrp` né un nuovo terminale nella stessa sessione. Dopo il
   riavvio, verifica con `id -nG` prima di procedere.

4. **Il controllo dello spazio disco guardava `/srv` con un percorso
   fisso.** Riscritto in `bc7a90d` per leggere `storage.libvirt_pool_path`
   e `storage.artifacts_dir` dalla configurazione reale e risalire al
   mount point vero — è il motivo per cui la sezione storage sopra
   funziona con `/srv` come mount dedicato invece di dover reinventare
   qualcosa.

Due comportamenti non sono bug, non toccarli:

- `validate-config.py` sull'esempio spedito avvisa sempre che
  `media.windows.iso_path` è vuoto. È strutturale, e la CI lo sa già dal
  commit `0f937e9`.
- Lo snap `docker` va evitato: entra in conflitto con `docker-ce`, che è
  quello che `install-host DOCKER=1` installa.

## Regole di ingaggio

- `set -Eeuo pipefail` in ogni script nuovo, trap sugli errori, variabili
  quotate.
- Nessun comando inventato: se non sei sicuro della sintassi di uno
  strumento, verificalo contro la documentazione ufficiale prima di
  eseguirlo.
- Prima di ogni push: `make validate && make lint` locali.
  ansible-lint in profilo production, ShellCheck, yamllint e
  markdownlint devono restare a zero findings.
- Nessun segreto, chiave privata, ISO o file `.wim` va mai committato. La
  password root ESXi in particolare, mai in nessun file che lasci questa
  macchina.
- Non forzare mai un push, non riscrivere la storia condivisa del
  branch.
- Se un controllo blocca e la tentazione è `--skip-checks` o
  disabilitare il controllo: fermati. O il controllo ha ragione e va
  risolto il problema, o il controllo ha torto e va corretto lui — non
  aggirato.
- Un limite ambientale reale si documenta con la stessa onestà di
  `docs/LIMITATIONS.md`: cosa non funziona, perché, cosa servirebbe per
  risolverlo altrove.

### Branch e push

`claude/gitops-infrastructure-poc-9losz4` può essere lavorato anche da
altre sessioni in parallelo stanotte.

1. `git pull` prima di ogni sessione di lavoro e prima di ogni push.
2. Commit piccoli e frequenti, non un unico commit a fine turno.
3. Se un conflitto reale emerge, fermati e segnalalo nel logbook invece
   di forzare una risoluzione a caso.
4. Se preferisci isolarti, lavora su un branch dedicato — ad esempio
   `validation/esxi-nested` — e apri una pull request verso
   `claude/gitops-infrastructure-poc-9losz4` a fine lavoro. In quel caso
   dillo esplicitamente nel logbook finale.

## Piano di lavoro

Ogni fase del repository è idempotente per costruzione: se qualcosa
fallisce a metà, correggi la causa e rilancia lo stesso comando.

### Fase 0 — Creazione della VM

Accedi al client ESXi/vCenter con le credenziali fornite fuori banda.
Crea la VM secondo la specifica sopra, con le due impostazioni
obbligatorie (CPU e memoria) e il secondo disco dal pool da 5 TB. Installa
Ubuntu Server 24.04 da ISO ufficiale: sistema completo, non minimized,
con OpenSSH server selezionato durante l'installazione, nessuno snap in
evidenza — in particolare non lo snap `docker`.

**Non remasterizzare la ISO.** Non serve costruire un'immagine
personalizzata: hai accesso alla console remota della VM tramite il
client ESXi/vCenter, esattamente come un operatore umano. Due strade,
entrambe senza toccare l'immagine ufficiale:

- **Interattiva** — apri la console della VM e rispondi ai passi
  dell'installer una volta, come un'installazione normale. Per una
  singola VM è la via più rapida.
- **Non presidiata, senza remaster** — Ubuntu Server supporta
  l'autoinstall passando `autoinstall ds=nocloud-net;s=http://<ip>:<porta>/`
  come parametro al kernel dalla schermata di boot della ISO (premi `e`
  sulla voce di avvio per modificarla), con un seed NoCloud
  (`user-data`/`meta-data`) servito via HTTP da una macchina qualunque
  raggiungibile dalla VM durante l'installazione. È la stessa tecnica
  che questo stesso PoC usa già per i target interni via PXE
  (`ds=nocloud;s=http://.../<host>/` — vedi `ansible/templates/`), quindi
  resta coerente con il resto del progetto invece di introdurne una
  nuova. Il remaster dell'ISO (come fa `kickstart-berlin` per il
  bare-metal, dove non c'è nessuna console interattiva disponibile) è
  uno strumento per un problema diverso da questo.

Apri il primo logbook con l'esito di:

```bash
hostnamectl --static; . /etc/os-release; echo "$PRETTY_NAME"
ls -l /dev/kvm 2>&1; grep -cE 'vmx|svm' /proc/cpuinfo
nproc; free -g | head -2
df -h / /srv 2>&1 | tail -2
```

Se `/dev/kvm` manca del tutto già a questo punto, la causa quasi certa è
la prima impostazione obbligatoria non applicata correttamente in fase di
creazione — torna al client e verificala prima di proseguire.

### Fase 1 — Sistema aggiornato e storage montato

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y open-vm-tools
sudo reboot
```

Dopo il riavvio, esegui i comandi della sezione storage sopra (partiziona,
formatta, monta `/srv`, aggiungi a `/etc/fstab`).

### Fase 2 — Claude CLI, se non già presente

Il pacchetto `nodejs` di Ubuntu 24.04 si ferma alla versione 18; questo
progetto richiede Node 22+. La via più semplice evita del tutto Node:

```bash
curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh
less /tmp/claude-install.sh
bash /tmp/claude-install.sh
```

Se preferisci npm, serve prima Node 22 da NodeSource e un prefisso nella
home per non richiedere `sudo` su `npm install -g`. Se sei già questa
sessione Claude e stai leggendo questo file, questo passo è probabilmente
già superato — verificalo e passa oltre.

### Fase 3 — Repository

```bash
git clone https://github.com/danielesalpietro/FORGE-AI.git
cd FORGE-AI && git checkout claude/gitops-infrastructure-poc-9losz4
git log --oneline -6   # deve contenere c8ed22e, 427a1f5, bc7a90d
```

Non creare `.venv` a mano, non lanciare ancora `make validate`: ci pensa
`install-host` nella fase successiva.

### Fase 4 — Host pronto

```bash
make install-host DOCKER=1
sudo reboot
```

Dopo la riconnessione:

```bash
id -nG   # kvm e libvirt devono comparire
cp config/poc.example.yml config/poc.yml
# applica qui le due righe storage.artifacts_dir / storage.libvirt_pool_path
. .venv/bin/activate
make validate && make lint
./bootstrap/check-prerequisites.sh --verbose
```

Deve risultare `READY`. I warning attesi sono `media-ubuntu` (nessuna ISO
scaricata ancora) e `media-windows` (nessuna ISO fornita, per design).
Ogni altro errore va investigato e risolto prima di proseguire.

### Fase 5 — Control plane

```bash
./bootstrap/bootstrap.sh
make ps
make test-integration
make test-molecule
```

Questi ultimi due comandi non sono mai stati eseguiti in nessun ambiente
prima d'ora. Il loro esito, qualunque sia, va nel logbook per intero.

### Fase 6 — Media e rete di provisioning

```bash
make prepare-ubuntu-media
make deploy-pxe
```

### Fase 7 — Provisioning del target Ubuntu

```bash
make create-vms
make provision-ubuntu
```

Segui l'installazione dalla console seriale in una seconda shell:

```bash
make console HOST=poc-ubuntu-01
```

### Fase 8 — Configurazione e verifica

```bash
make configure
make validate-deployment
make smoke-test
```

### Fase 9 — Idempotenza

```bash
make configure
```

La seconda esecuzione deve riportare `changed=0` per ogni host. Copia
l'output completo nel logbook.

### Fase 10 — Drift e riconciliazione

```bash
make drift
make drift-report
make reconcile
make report
```

### Fase 11 — Target Windows (condizionale)

Solo se Daniele ha fornito una ISO di Windows Server 2025 e il suo path.
Altrimenti salta e scrivilo nel riepilogo finale: non è un blocco, è uno
scope non ancora aperto.

### Fase 12 — Consolidamento

Chiudi ogni logbook aperto, scrivi il riepilogo finale, verifica lo stato
di CI sulla pull request se hai pushato qualcosa.

## Formato dei logbook

Percorso: `docs/logbook/NN-slug-breve.md`, numerato nell'ordine delle fasi
sopra. Se `docs/logbook/` non esiste ancora — un'altra sessione potrebbe
averlo già creato lavorando in parallelo sull'altro percorso — verifica
prima di duplicare la struttura; se esiste già un `README.md` lì dentro
non riscriverlo, aggiungi solo i tuoi file numerati.

Template per ogni file, una voce per intervento significativo:

```markdown
## AAAA-MM-GG HH:MM UTC — titolo breve

**Contesto**: cosa si stava tentando di fare.

**Comando/i**:

    il comando esatto, non parafrasato

**Osservato**: l'output rilevante, incollato per intero se breve,
altrimenti la parte che conta con una nota su cosa è stato omesso.

**Problema** (solo se qualcosa non ha funzionato): sintomo, causa radice
una volta trovata, correzione applicata con l'hash del commit se
pushata, o limite ambientale se non risolvibile da questo repository.

**Stato**: fatto / bloccato / rimandato, e perché.
```

Non riassumere l'output degli step critici (idempotenza, test mai
eseguiti prima, qualunque fallimento) — è lì che sta l'informazione che
conta. E non includere mai la password root ESXi in un logbook, nemmeno
per errore in un output incollato per intero: controlla prima di
salvare.

## Se qualcosa si rompe

1. Riproduci il problema una seconda volta prima di concludere che è
   reale.
2. Isola la causa radice, non fermarti al primo sintomo.
3. Se serve un comando che non conosci a memoria, verificalo contro la
   documentazione ufficiale prima di usarlo.
4. Se è un bug del repository: correggilo, verifica con
   `make validate && make lint` più il test specifico che lo aveva
   rivelato, poi commit e push con un messaggio che spiega la causa.
5. Se non è un bug del repository ma un limite reale di questo ambiente:
   documentalo nel logbook con la stessa onestà di
   `docs/LIMITATIONS.md`.
6. Non disabilitare un controllo per farlo tacere.

## Cosa non fare

- Non eseguire `make destroy` o `make destroy-all` a meno che non sia
  esplicitamente il task assegnato in quel momento.
- Non installare lo snap `docker`.
- Non committare nessuna ISO, file `.wim`, chiave privata o segreto — e
  in particolare non la password root ESXi, in nessuna forma, in nessun
  file che lasci questa macchina.
- Non forzare un push né riscrivere la storia del branch condiviso.
- Non toccare nessuna altra VM, datastore o impostazione dell'host ESXi
  al di fuori di quanto serve per la VM di questo collaudo: root ha
  accesso a tutto l'host, il tuo mandato è solo questa VM.

## Riepilogo finale — cosa deve contenere

- Quali fasi sono state completate, quali no e perché.
- Il nome del datastore da 5 TB usato per il disco dati, per riferimento
  futuro.
- L'elenco dei bug trovati e risolti, con hash di commit.
- L'esito testuale della prova di idempotenza.
- L'esito di `test-integration` e `test-molecule`, la prima volta che
  girano da qualche parte.
- Lo stato della pull request #1 dopo i tuoi push, se ne hai fatti.
- Conferma che nessun segreto sia finito in un file committato.
- Qualunque limite ambientale non risolvibile da questo repository.
