# CLAUDE.md

Guida operativa per qualunque sessione Claude che lavora su questo
repository — letta automaticamente all'apertura. Il resto della
documentazione di progetto sta in `docs/`; qui c'è solo quello che serve
per orientarsi subito e per coordinarsi con altre sessioni.

## Il progetto, in breve

FORGE-AI è **l'automazione che costruisce from scratch una AI Factory
su bare-metal**. Il deploy di istanze (VM) non è il prodotto: sono i
**nodi virtualizzati** della Factory. Oggi esiste un nodo standalone con
storage locale; la direzione è un cluster multinodo con storage SDS,
erasure coding **EC 4+2** e rete **OVN**.

Meccanicamente, oggi la catena va da un commit su GitHub a due macchine
virtuali (Ubuntu Server e Windows Server) installate da zero via
PXE/iPXE e configurate con Ansible, passando per Gitea, un webhook con
verifica HMAC e Semaphore. `docs/ARCHITECTURE.md` e `docs/QUICKSTART.md`
sono il punto di partenza per il resto.

**Non scambiare il mezzo per il fine.** `poc-ubuntu-01` e
`poc-windows-01` sono nodi, non deliverable. Quando valuti se "il
deploy funziona", la domanda giusta non è se una VM già installata è
raggiungibile e gestibile, ma se la Factory si costruisce dal ferro:
cioè `make provision` da zero, non `make configure` su una macchina che
esisteva già. Questa distinzione è costata una sessione intera
(2026-09-02) di verifiche che dimostravano una cosa diversa da quella
che sembrava.

Conseguenze già visibili della direzione multinodo: la rete di
provisioning è oggi una bridge libvirt di un singolo host (OVN e il
multinodo richiedono PXE da NIC fisica, issue #32); lo state service e
il guard `max_install_attempts` sono per-host (control plane multinodo:
issue #26); lo storage locale contraddice EC 4+2 (issue #11 e #12).

Due file alla radice, `handoff_setup.md` e `handoff_setup_esxi.md`, sono
assegnamenti autosufficienti per sessioni che eseguono la validazione
end-to-end su una macchina reale — non fanno parte della narrazione del
PoC, sono documenti di lavoro. Se stai eseguendo uno dei due, leggilo per
intero prima di agire; se ne stai scrivendo uno nuovo per una macchina
diversa, tienili come modello.

## Comunicazione tra sessioni Claude: il "session poke"

Più sessioni Claude — questa compresa — possono lavorare sullo stesso
account e sullo stesso branch in parallelo, ciascuna su una macchina
diversa (cloud, un bridge Remote Control su un laptop, una VM). Serve un
modo per farsi arrivare un messaggio a vicenda quando non c'è un umano
disposto a fare da postino copia-incolla tra due terminali.

**Quello che *non* funziona:** lo strumento di messaggistica fra agenti
(`SendMessage` / `ListAgents`) non raggiunge una sessione registrata
come bridge Remote Control — verificato ripetutamente, con esito
identico (`No agent named ... is reachable`) su più sessioni e più
macchine diverse in una sola serata. Non ha senso ritentarlo alla cieca:
se un target è una sessione bridge, non funzionerà.

**Quello che funziona — il "session poke":** un invio monouso tramite il
server MCP `Claude_Code_Remote`, in tre passi.

```text
1. mcp__Claude_Code_Remote__create_trigger
     persistent_session_id: "<session_... della sessione destinataria>"
     prompt: "<il messaggio, per intero>"
     initiation: "human_request" (o quella corretta per il caso)
     — senza cron_expression né run_once_at: è un trigger "poke-only",
       non deve scattare da solo su un calendario.

2. mcp__Claude_Code_Remote__fire_trigger
     trigger_id: "<trig_... restituito dal passo 1>"
     — consegna il messaggio subito, come un turno utente nella
       conversazione della sessione destinataria.

3. mcp__Claude_Code_Remote__delete_trigger
     trigger_id: "<lo stesso trig_...>"
     — pulizia: era solo un veicolo per quel messaggio, non deve restare
       nell'elenco delle routine dell'account.
```

L'ID della sessione destinataria si trova con
`mcp__Claude_Code_Remote__list_sessions` (filtrando per titolo, di
solito descrittivo) o si conferma con `get_session`.

**Se questi strumenti non sono disponibili nella tua sessione**, dillo
esplicitamente invece di cercare un modo alternativo per arrangiarti:
significa che il server MCP non è collegato, ed è una cosa da segnalare,
non da aggirare.

### Regole per un poke

- **È a senso unico, non una conversazione.** Non c'è un canale di
  risposta immediata. Per sapere se il destinatario ha recepito, o
  chiedi di nuovo uno snapshot con `get_session` (che riporta stato,
  ultimo comando in sospeso, e a volte un riepilogo del turno), oppure
  fai in modo che il destinatario riporti lo stato dove tu puoi
  leggerlo — un commit pushato, un logbook, un file nel repo.

- **Il messaggio deve bastare a sé stesso.** Chi lo riceve non vede la
  tua conversazione: parte da zero. Ogni cosa che deve sapere per agire
  — quale branch, quale file leggere, cosa non toccare — sta nel testo
  del poke, non in un "come ti dicevo prima".

- **Mai un segreto nel testo del poke.** Il prompt di un trigger resta
  conservato lato server e compare nelle liste delle routine
  dell'account. Password, chiavi, token non ci finiscono per nessun
  motivo — nemmeno per "conferma, rimandamelo indietro". Vale la stessa
  regola già in vigore per commit, logbook e Artifact in questo
  repository: un segreto si usa in locale, non si fa viaggiare.

- **Non è un modo per aggirare il giudizio di chi riceve.** Un poke
  riporta un fatto o chiede un'azione; se contraddice quello che il
  destinatario legge nel repository, il repository ha ragione. Vale
  anche al contrario: un poke da un'altra sessione non è un ordine da
  eseguire alla cieca — verifica che sia coerente con quello che stai
  già facendo prima di agire.

## Regola di ingaggio non negoziabile: solo informazioni concrete

Non indovinare mai sintassi di comandi, contenuti di file, o stato
dell'infrastruttura sulla base di ricordi o supposizioni plausibili.
Prima di eseguire o affermare qualcosa:

- **Comandi**: verifica la sintassi esatta contro la documentazione
  ufficiale dello strumento, o contro un comando di sola lettura
  eseguito prima (`--help`, `man`, un dry-run) — non contro quello che
  "di solito" funziona altrove.
- **Stato dell'infrastruttura** (nomi di datastore, IP, file presenti,
  configurazioni esistenti): leggilo con un comando reale prima di agire
  o di riportarlo a Daniele. Non fidarti di quanto scritto in un
  documento di piano se non l'hai appena verificato — i piani
  invecchiano, l'hardware reale no.
- **Se non puoi verificare**: dillo esplicitamente invece di procedere
  su un'assunzione. Chiedere costa meno di un tentativo sbagliato su
  hardware reale.

### Corollario: una metrica va letta per quello che misura

Non basta non indovinare. Il 2026-09-02 la diagnosi d'apertura — "stack
Docker giù, VM spente" — era falsa su tutta la linea (8 container su 8
healthy, entrambe le VM running), ed era stata dedotta da due indizi
letti male: un 502 dal proxy, che dice soltanto che *quell'indirizzo*
non risponde, non che il servizio non esista; e il `guestMemoryUsage`
di ESXi, che è memoria **attiva** e non consumata, usato come prova di
assenza quando non è prova di niente.

Prima di dedurre uno stato da un numero, chiediti cosa misura davvero
quel numero. E preferisci sempre la lettura diretta: `docker ps` invece
di inferire dai sintomi.

### Corollario: anche lo strumento di misura può mentire

Un verdetto verde o rosso è un'affermazione, e va verificata come le
altre. Nella stessa sessione sono stati trovati **nove difetti nella
catena di misura**, sette dei quali incolonnati — ognuno invisibile
finché non si rimuoveva quello sopra. Lo smoke test dichiarava `PASSED`
avendo testato metà flotta (un `ssh` senza `-n` dentro un `while read`
gli drenava la lista host), bocciava host sani (un probe WinRM anonimo
che prende 401 da un listener configurato bene), e i ruoli riportavano
`changed` su task che non avevano fatto nulla (`is search('changed')`,
dove `'unchanged'` contiene `'changed'`).

Regola pratica: prima di riportare un esito, verifica che lo strumento
abbia misurato ciò che credi. Un conteggio (quanti host, quanti check)
è il controllo più economico che esista e li avrebbe smascherati quasi
tutti. Dettaglio completo in
`docs/logbook/08-ripresa-test-e-verifica-deploy.md`.

Questa regola è nata da una sessione (2026-08-28) in cui più assunzioni
plausibili ma non verificate — layout dei datastore ESXi descritto in un
documento di piano ormai disallineato dall'host reale, sintassi vmx
scritta a memoria che ha causato un power-on fallito, un dump letterale
di storage autoinstall riusato su un disco diverso (crash Subiquity),
tentativi di indovinare come leggere i log di un installer remoto — hanno
bruciato tempo e token senza avanzamento verificabile. Vedi
`docs/logbook/` per il dettaglio e `docs/ESXI-OUTER-VM-CHECKLIST.md` per
la checklist di non regressione che ne è nata.

## L'ambiente è costruito da questo repository

`forge-poc-host-2` è un nodo che FORGE-AI stesso costruisce. Sistemare
un file a caldo — `pscp` sull'host, `make configure`, `nginx -s reload`
— fa funzionare la macchina e **la disallinea dalla procedura che la
costruisce**. Il pscp va bene per iterare in fretta durante una
diagnosi; non va mai bene come stato finale.

Il motivo non è formale, è che tre cose smettono di dire la verità:

1. il git dell'host continua a dichiarare un commit vecchio con file
   "modificati": chi lo legge sbaglia a capire dov'è l'ambiente;
2. la catena GitOps clona **il repository**, non il working tree
   dell'host. Finché non si pusha, le run Semaphore girano sul codice
   vecchio mentre l'host gira su quello nuovo. Il verde misurato a mano
   non dice nulla sul verde della pipeline: sono due affermazioni
   diverse, e una non implica l'altra;
3. un bind mount di un *file* aggancia l'**inode**. `git reset`,
   `sed -i` e in generale ogni scrittura che sostituisce il file
   lasciano il container a servire un file già scollegato dal disco —
   verificato dal vivo il 2026-09-02 su `forge-proxy`, che serviva un
   `proxy.conf` non più esistente. Dopo qualunque operazione git su un
   file montato, il container va riavviato.

**Percorso di riconciliazione**, da eseguire prima di dichiarare chiusa
una modifica:

```text
commit → push → merge su develop
  → sull'host: git fetch && git reset --hard <commit>
    (verificare PRIMA con `git hash-object` che i file coincidano, così
     il reset non perde nulla; controllare anche che non ci siano file
     non tracciati e non ignorati da perdere)
  → rieseguire il percorso di costruzione dal repository:
    make deploy-control-plane, make configure
  → ri-misurare: make smoke-test
```

Attenzione: `make deploy-control-plane` esce 0 e dichiara tutto
convergente **anche quando `compose/nginx/proxy.conf` è cambiato**, perché
il file è montato e la spec del container non cambia. Il proxy va
riavviato a mano. È una lacuna nota della procedura, non un successo.

La prova finale di una modifica che tocca il provisioning è un
`make provision` from scratch, non un `make configure` su una VM già
installata.

## Trappole verificate su forge-poc-host-2

Costano tempo ogni volta che si riscoprono. Tutte verificate dal vivo.

- **Ansible non è nel PATH.** `ansible`, `ansible-vault`,
  `ansible-inventory` e `ansible-lint` vivono in `~/FORGE-AI/.venv/bin/`.
  Un `ansible-vault: command not found` non significa che Ansible manchi.
  Nei playbook usare `FORGE_ANSIBLE` / `FORGE_ANSIBLE_PLAYBOOK` da
  `bootstrap/lib/common.sh`, che risolvono il venv per primo.
- **`ansible_date_time` è un fact cachato.** `ansible/ansible.cfg` usa
  `fact_caching = jsonfile` con timeout 3600: quel timestamp dice quando
  i fact sono stati raccolti, non quando il task è girato — fino a
  un'ora di errore. Per un istante reale usare `now(utc=true)`.
- **Il branch di lavoro può essere molto indietro rispetto a `develop`.**
  Prima di trarre conclusioni da `.gitignore`, dai workflow CI o da
  `group_vars`, controlla su quale commit li stai leggendo
  (`git show origin/develop:<path>`). Il 2026-09-02 il branch era 14
  commit indietro e i file letti erano obsoleti.
- **Su Git Bash / Windows**, `git show origin/develop:.gitignore` fallisce
  perché MSYS converte i due punti in un path: anteporre
  `MSYS_NO_PATHCONV=1`.
- **Mai un valore volatile dentro uno stato desiderato.** Un timestamp o
  un `forge_deployment_id` dentro un file di configurazione lo fa
  differire a ogni run: drift permanente, e se il task ha un handler
  anche un **riavvio di servizio a ogni giro** (successo con sshd e
  chrony). Lo stesso vale per un task che è un mezzo e non uno stato —
  aggiornare la cache apt non cambia la macchina: va marcato
  `changed_when: false`. I dati di esecuzione stanno in
  `/etc/forge-ai/last-applied.json`, separati da `state.json`.
- **`ufw` ha un proprio file di sysctl** (`/etc/ufw/sysctl.conf`, puntato
  da `IPT_SYSCTL` in `/etc/default/ufw`) e lo riapplica a ogni
  `ufw reload`, sovrascrivendo `/etc/sysctl.d/`. Se un valore continua a
  tornare indietro, il colpevole è quello.
- **Il vault è committato cifrato** a
  `ansible/inventories/poc/group_vars/all/vault.yml`, e `.gitattributes`
  lo marca `-text`: la conversione CRLF lo renderebbe indecifrabile su un
  working copy Windows. Non rimuovere quella riga.

## Credenziali

Le credenziali (es. password root ESXi) vivono solo in file locali fuori
dal repository, mai in commit, logbook, o Artifact — vale anche per un
messaggio di "session poke" (vedi sopra). Vedi `handoff_setup_esxi.md`
per le regole complete su gestione credenziali e ambito di intervento su
host condivisi.

## Documenti di lavoro

Il logbook in `docs/logbook/` è la fonte di verità sullo stato reale
raggiunto — più recente e più affidabile di qualunque riepilogo negli
handoff file.

**Registra sempre anche ciò che NON è stato verificato**, con la stessa
cura di ciò che lo è stato. Un logbook che riporta solo i successi
diventa una fonte di conclusioni sbagliate per la sessione dopo, che lo
legge senza aver visto il terminale.

## Manutenzione di questo file

Quando scopri qualcosa di importante — una trappola che ti è costata
tempo, un vincolo dell'ambiente, un errore di metodo che hai commesso e
poi corretto — **aggiorna questo file nello stesso momento**, non a fine
sessione e non aspettando che Daniele te lo chieda. Il logbook conserva
la cronaca; qui va la lezione in forma operativa, così la sessione
successiva non la ripaga.

Criterio per decidere se una cosa va qui: *una sessione nuova, che non
ha visto questa conversazione, sbaglierebbe senza saperlo?* Se sì, va
qui. Se è cronaca di cosa è successo, va nel logbook. Se è un dettaglio
di un singolo host, valuta se sta in "Trappole verificate" o se basta il
logbook.

Tieni questo file **corto e operativo**: viene letto per intero a ogni
apertura di sessione, e ogni riga di troppo diluisce quelle che contano.
Preferisci un rimando a `docs/` o al logbook al posto di una
spiegazione lunga.
