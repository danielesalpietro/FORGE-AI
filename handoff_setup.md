# Handoff: validazione e2e su ZBook nested

Documento di lavoro, non parte della narrazione del PoC. Se lo stai leggendo
sei la sessione Claude con accesso SSH alla VM di validazione: questo file è
il tuo assegnamento completo. Nessun contesto precedente ti è stato passato
a parte questo file — leggilo tutto prima di eseguire il primo comando.

## Obiettivo

Portare il PoC FORGE-AI a un'esecuzione end-to-end reale (non solo validata)
sulla VM Ubuntu Server 24.04 con virtualizzazione annidata, ospitata su una
ZBook con VMware Workstation. Almeno il target Ubuntu deve arrivare a
`ready`. Ogni problema che incontri va risolto nel codice, quando è un bug
del repository, o documentato con causa e limite quando non lo è. Ogni fase
va registrata in un logbook secondo il formato più sotto.

Non sei la prima sessione a lavorarci stanotte: repository, branch e
correzioni già pushate sono descritti sotto in "Stato noto all'apertura di
questo handoff". Verificalo comunque tu stesso invece di fidarti: potrebbe
essere cambiato.

## Cosa significa "fatto"

- `make validate` e `make lint` verdi sull'ospite.
- `./bootstrap/check-prerequisites.sh --verbose` in stato `READY` (i warning
  sui media sono attesi, vedi sotto).
- Il control plane (`make bootstrap`) su e verificato, non solo avviato:
  `make test-integration` e `make test-molecule` eseguiti e il loro esito
  — pass o fail — registrato nel logbook. Non sono mai girati da nessuna
  parte prima d'ora: qualunque risultato è un dato nuovo.
- Il target `poc-ubuntu-01` installato via PXE, configurato, e verificato
  con `make validate-deployment` e `make smoke-test`.
- La prova di idempotenza eseguita e il suo risultato riportato
  testualmente nel logbook, non riassunto: è un'affermazione della PR
  (<https://github.com/danielesalpietro/FORGE-AI/pull/1>) mai controllata
  su hardware reale.
- Drift detection e riconciliazione eseguiti almeno una volta.
- Ogni bug di repository trovato: corretto, testato, committato e pushato
  con un messaggio che spiega la causa, non solo il sintomo.
- Un logbook per fase, più un riepilogo finale con l'elenco di cosa è
  stato completato, cosa resta aperto e perché.
- Il target Windows resta esplicitamente fuori scope finché Daniele non
  fornisce una ISO di Windows Server 2025 — vedi la sezione dedicata.

## Stato noto all'apertura di questo handoff

Raccolto da una sessione precedente via copia-incolla nel terminale, quindi
di seconda mano e probabilmente parziale:

- VM `claude-code-test`, utente `dsalpietro`, Ubuntu Server 24.04, VMware
  Workstation con VT-x/EPT esposto al guest.
- Repository clonato in `~/FORGE-AI`, branch
  `claude/gitops-infrastructure-poc-9losz4`.
- `make install-host DOCKER=1` eseguito con successo.
- L'ultimo `git log` osservato si fermava al commit `427a1f5`. Se il tuo
  checkout è più indietro, `git pull` prima di continuare — vedi sotto i
  tre bug già corretti che altrimenti rifaresti scoprire da zero.
- L'ultimo esito noto di `check-prerequisites.sh` segnalava `/dev/kvm`
  non scrivibile: i gruppi `kvm` e `libvirt` erano stati aggiunti con
  `usermod` ma non avevano ancora effetto nella sessione attiva in quel
  momento. Non è detto sia ancora così: verifica con `id -nG` prima di
  agire.

## Bug già trovati e corretti stasera — non ripeterli

Tre problemi reali sono già stati diagnosticati e risolti in questo stesso
branch. Se il tuo `git log --oneline -5` non li contiene, `git pull` prima
di andare oltre: altrimenti li ricolpisci uno per uno, come è successo la
prima volta.

1. **`libvirt-python` non compila senza `libvirt-dev`.** È pubblicato su
   PyPI solo come sorgente: la compilazione cerca `libvirt.pc` via
   `pkg-config` e senza header Python e compilatore fallisce con un
   errore che non nomina nessun pacchetto Debian. Corretto in `c8ed22e`
   aggiungendo `pkg-config`, `libvirt-dev`, `python3-dev`, `gcc` a
   `bootstrap/prepare-host.sh`.

2. **`ansible-playbook` non trovato durante `bootstrap.sh`.**
   `install-host` crea `ansible-playbook` dentro `.venv/`, ma
   `bootstrap.sh` e tre script in `scripts/` chiamavano il comando nudo,
   contando su un `PATH` attivato a mano — cosa che non succede quando si
   rilancia lo script in una shell nuova. Corretto in `427a1f5` con
   `FORGE_ANSIBLE_PLAYBOOK` in `bootstrap/lib/common.sh`, risolto una
   volta sola e riusato ovunque.

3. **L'appartenenza ai gruppi `kvm`/`libvirt` non si propaga con un
   logout parziale.** In una sessione bridge Remote Control, "uscire e
   rientrare" a parole non basta se il processo che esegue i comandi non
   viene davvero rigenerato: i gruppi supplementari di un processo si
   fissano al login. **Il fix è un riavvio della VM**, non `newgrp` né un
   nuovo terminale aperto nella stessa sessione. Dopo il riavvio,
   verifica con `id -nG` prima di procedere.

Altri due comportamenti non sono bug, non toccarli:

- `validate-config.py` sull'esempio spedito avvisa sempre che
  `media.windows.iso_path` è vuoto. È strutturale — nessun path
  committabile può puntare a media Windows — e la CI lo sa già dal
  commit `0f937e9`. Non serve `--strict` lì.
- Lo snap `docker` va evitato: entra in conflitto con `docker-ce`, che è
  quello che `install-host DOCKER=1` installa.

## Regole di ingaggio

Le stesse che governano il resto del repository, non regole nuove per
questo handoff:

- `set -Eeuo pipefail` in ogni script nuovo, trap sugli errori, variabili
  quotate.
- Nessun comando inventato: se non sei sicuro della sintassi di uno
  strumento (`virsh`, `nmcli`, `lvextend`, quello che serve), verificalo
  contro la documentazione ufficiale prima di eseguirlo, non a tentativi.
- Prima di ogni push: `make validate && make lint` locali. Il repository
  ha ansible-lint in profilo production, ShellCheck, yamllint e
  markdownlint tutti a zero findings — un push che li rompe si nota
  subito e costa un ciclo di CI.
- Nessun segreto, chiave privata, ISO o file `.wim` va mai committato.
  Il generatore di segreti scrive con `install -m 0600 /dev/null` prima
  del contenuto: se scrivi tu qualcosa di sensibile, fai lo stesso.
- Non forzare mai un push, non riscrivere la storia condivisa del
  branch.
- Se un controllo blocca e la tentazione è `--skip-checks` o disabilitare
  il controllo: fermati. O il controllo ha ragione e va risolto il
  problema, o il controllo ha torto e va corretto lui — non aggirato.
- Un limite ambientale reale (qualcosa che questo repository non può
  risolvere) si documenta con la stessa onestà di `docs/LIMITATIONS.md`:
  cosa non funziona, perché, e cosa servirebbe per risolverlo altrove.

### Branch e push

Questo branch (`claude/gitops-infrastructure-poc-9losz4`) è attivamente
lavorato anche da un'altra sessione stanotte. Per evitare di scontrarti
con lei:

1. `git pull` prima di ogni sessione di lavoro e prima di ogni push, non
   solo all'inizio.
2. Preferisci commit piccoli e frequenti a un unico commit enorme a fine
   turno: se un conflitto nasce, è più facile risolverlo su un diff
   piccolo.
3. Se un conflitto reale emerge (stesso file, stesse righe), fermati e
   segnalalo nel logbook invece di forzare una risoluzione a caso — non
   sei tu ad avere il contesto di entrambe le modifiche.
4. Se preferisci isolarti del tutto, lavora su un branch dedicato, ad
   esempio `validation/zbook-nested`, e apri una pull request verso
   `claude/gitops-infrastructure-poc-9losz4` a fine lavoro invece di
   pushare direttamente. In quel caso dillo esplicitamente nel logbook
   finale, perché chi legge la PR #1 sappia dove guardare.

## Precondizioni da verificare prima di iniziare

Sola lettura, apri il primo logbook con questo output:

```bash
hostnamectl --static; . /etc/os-release; echo "$PRETTY_NAME"
id -nG
ls -l /dev/kvm 2>&1; grep -cE 'vmx|svm' /proc/cpuinfo
nproc; free -g | head -2
df -h / | tail -1
cd ~/FORGE-AI && git status && git log --oneline -5
test -d .venv && echo "venv presente" || echo "venv assente"
```

Se `kvm` e `libvirt` non compaiono in `id -nG`, applica il fix del punto 3
sopra (riavvio) prima di qualunque altra cosa. Tutto il resto dipende da
quello.

## Piano di lavoro

Ogni fase è idempotente per costruzione nel repository: se qualcosa fallisce
a metà, correggi la causa e rilancia lo stesso comando, non serve smontare
niente a mano. Segna l'inizio e la fine di ogni fase nel logbook.

### Fase 0 — Ricognizione

Le precondizioni sopra, più un `./bootstrap/check-prerequisites.sh
--verbose` di partenza. Apri il logbook di fase 0 con l'esito integrale.

### Fase 1 — Aggiornamento e validazione

```bash
cd ~/FORGE-AI
git pull
. .venv/bin/activate
make validate && make lint
```

Se `.venv` non esiste ancora, non crearlo a mano: è compito di
`install-host`, fase successiva.

### Fase 2 — Host pronto

Se `install-host` non è mai stato eseguito, o se hai il dubbio che sia
incompleto:

```bash
make install-host DOCKER=1
```

Poi, obbligatorio, il riavvio descritto sopra — non un logout parziale:

```bash
sudo reboot
```

Dopo la riconnessione:

```bash
id -nG   # kvm e libvirt devono comparire
./bootstrap/check-prerequisites.sh --verbose
```

Deve risultare `READY`. I warning attesi sono `media-ubuntu` (nessuna ISO
scaricata ancora) e `media-windows` (nessuna ISO fornita, per design). Ogni
altro errore va investigato e risolto prima di proseguire — non è previsto
che restino errori qui.

### Fase 3 — Control plane

```bash
./bootstrap/bootstrap.sh
```

È lo script che ha già fallito una volta stanotte sul bug numero 2 sopra.
Se fallisce di nuovo con un errore diverso, quello è nuovo territorio:
diagnosticalo, correggilo nel codice se è un bug del repository, e
documenta la causa radice nel logbook — non solo il traceback.

A stack in piedi:

```bash
make ps
make test-integration
make test-molecule
```

Questi due comandi non sono mai stati eseguiti in nessun ambiente prima
d'ora — né in CI, che non ha un hypervisor, né su alcun host reale. Il loro
esito, qualunque sia, va nel logbook per intero: se passano, è la prima
conferma che quella parte del PoC funziona davvero; se falliscono, è la
prima informazione reale su un bug altrimenti solo teorico.

### Fase 4 — Media e rete di provisioning

```bash
make prepare-ubuntu-media
make deploy-pxe
```

`prepare-ubuntu-media` verifica il checksum contro `SHA256SUMS` ufficiale:
se fallisce la verifica, non forzare il proseguimento, è esattamente il
tipo di controllo che esiste per essere rispettato.

### Fase 5 — Provisioning del target Ubuntu

```bash
make create-vms
make provision-ubuntu
```

Segui l'installazione dalla console seriale in una seconda shell:

```bash
make console HOST=poc-ubuntu-01
```

Registra nel logbook tempi approssimativi (quanto ci ha messo, non un
benchmark preciso — siamo sotto nested, i tempi non sono rappresentativi
di un'installazione su bare metal) ed eventuali anomalie osservate in
console.

### Fase 6 — Configurazione e verifica

```bash
make configure
make validate-deployment
make smoke-test
```

### Fase 7 — Idempotenza

```bash
make configure
```

La seconda esecuzione deve riportare `changed=0` per ogni host. Copia
l'output completo nel logbook, non un riassunto: se il numero non è zero,
è un bug reale della PR e va investigato, non minimizzato.

### Fase 8 — Drift e riconciliazione

```bash
make drift
make drift-report
make reconcile
make report
```

### Fase 9 — Target Windows (condizionale)

Solo se Daniele ha fornito una ISO di Windows Server 2025 e il suo path.
Se non l'hai ricevuta, salta questa fase e scrivilo nel riepilogo finale:
non è un blocco, è uno scope non ancora aperto.

```bash
make prepare-windows-media
make windows-images
make provision-windows
```

Sotto nested l'installazione è sensibilmente più lenta che su bare metal:
lanciala e continua con altro nel frattempo, non restare in attesa.

### Fase 10 — Consolidamento

Chiudi ogni logbook aperto, scrivi il riepilogo finale (formato sotto), e
verifica lo stato di CI sulla pull request se hai pushato qualcosa:
<https://github.com/danielesalpietro/FORGE-AI/pull/1>.

## Formato dei logbook

Il repository non ha ancora questa convenzione: la introduci tu, seguendo
lo stile già in uso nel repository gemello `kickstart-berlin` dello stesso
autore, dove ogni fase di collaudo su hardware reale ha il proprio file
numerato.

Percorso: `docs/logbook/NN-slug-breve.md`, numerato nell'ordine delle fasi
sopra (`00-ricognizione.md`, `01-host-pronto.md`, e così via). Crea anche
`docs/logbook/README.md` che spiega perché la cartella esiste — la stessa
regola che il resto del repository segue per ogni directory non ovvia.

Template per ogni file, una voce per intervento significativo:

```markdown
## AAAA-MM-GG HH:MM UTC — titolo breve

**Contesto**: cosa si stava tentando di fare.

**Comando/i**:

    il comando esatto, non parafrasato

**Osservato**: l'output rilevante, incollato per intero se breve,
altrimenti la parte che conta con una nota su cosa è stato omesso.

**Problema** (solo se qualcosa non ha funzionato): sintomo, causa radice
una volta trovata, correzione applicata con l'hash del commit se pushata,
o limite ambientale se non risolvibile da questo repository.

**Stato**: fatto / bloccato / rimandato, e perché.
```

Non riassumere l'output degli step critici (idempotenza, test mai
eseguiti prima, qualunque fallimento) — è lì che sta l'informazione che
conta.

## Se qualcosa si rompe

1. Riproduci il problema una seconda volta prima di concludere che è
   reale e non un fluke.
2. Isola la causa radice, non fermarti al primo sintomo — i tre bug già
   trovati stasera avevano tutti un messaggio d'errore che, letto alla
   lettera, avrebbe portato nella direzione sbagliata.
3. Se serve un comando che non conosci a memoria, verificalo contro la
   documentazione ufficiale dello strumento prima di usarlo.
4. Se è un bug del repository: correggilo, verifica con `make validate &&
   make lint` più il test specifico che lo aveva rivelato, poi commit e
   push con un messaggio che spiega la causa — non "fix bug", ma cosa
   causava cosa.
5. Se non è un bug del repository ma un limite reale di questo ambiente
   (hardware, rete, qualcosa fuori dal controllo del codice): documentalo
   nel logbook con la stessa onestà di `docs/LIMITATIONS.md` — cosa non
   funziona, perché, cosa servirebbe per risolverlo altrove. Non è un
   fallimento del tuo lavoro, è un dato utile.
6. Non disabilitare un controllo per farlo tacere. Se un controllo del
   repository sembra sbagliato — non solo scomodo — dillo nel logbook con
   la tua analisi, ma non modificarlo senza essere sicuro del perché.

## Cosa non fare

- Non eseguire `make destroy` o `make destroy-all` a meno che non sia
  esplicitamente il task assegnato in quel momento: sono distruttivi e
  irreversibili sullo stato del PoC.
- Non installare lo snap `docker`.
- Non committare nessuna ISO, file `.wim`, chiave privata o segreto — il
  repository ha un secret scanner in CI che lo bloccherebbe comunque, ma
  è più pulito non arrivarci.
- Non forzare un push né riscrivere la storia del branch condiviso.
- Se serve uno snapshot VMware Workstation (prima di una fase rischiosa,
  o come punto di ripristino), non puoi crearlo da una sessione SSH nel
  guest: quella è un'azione sull'host Windows. Chiedilo a Daniele quando
  serve, indicando esattamente il momento e perché.

## Riepilogo finale — cosa deve contenere

Un'ultima sezione, in `docs/logbook/` o come messaggio diretto a Daniele,
con:

- Quali fasi sono state completate, quali no e perché.
- L'elenco dei bug trovati e risolti, con hash di commit.
- L'esito testuale della prova di idempotenza.
- L'esito di `test-integration` e `test-molecule`, la prima volta che
  girano da qualche parte.
- Lo stato della pull request #1 dopo i tuoi push, se ne hai fatti.
- Qualunque limite ambientale non risolvibile da questo repository,
  scritto con la stessa onestà con cui è scritto il resto del progetto.
