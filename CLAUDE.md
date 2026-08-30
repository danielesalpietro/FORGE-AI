# CLAUDE.md

Guida operativa per qualunque sessione Claude che lavora su questo
repository — letta automaticamente all'apertura. Il resto della
documentazione di progetto sta in `docs/`; qui c'è solo quello che serve
per orientarsi subito e per coordinarsi con altre sessioni.

## Il progetto, in breve

FORGE-AI è un PoC di provisioning GitOps: da un commit su GitHub a due
macchine virtuali (Ubuntu Server e Windows Server) installate da zero via
PXE/iPXE e configurate con Ansible, passando per Gitea, un webhook con
verifica HMAC e Semaphore. `docs/ARCHITECTURE.md` e `docs/QUICKSTART.md`
sono il punto di partenza per il resto.

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

Questa regola è nata da una sessione (2026-08-28) in cui più assunzioni
plausibili ma non verificate — layout dei datastore ESXi descritto in un
documento di piano ormai disallineato dall'host reale, sintassi vmx
scritta a memoria che ha causato un power-on fallito, un dump letterale
di storage autoinstall riusato su un disco diverso (crash Subiquity),
tentativi di indovinare come leggere i log di un installer remoto — hanno
bruciato tempo e token senza avanzamento verificabile. Vedi
`docs/logbook/` per il dettaglio e `docs/ESXI-OUTER-VM-CHECKLIST.md` per
la checklist di non regressione che ne è nata.

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
