# 08 — Ripresa dei test: verifica che il deploy Linux e Windows sia ancora possibile

## Contesto

Sessione del 2026-09-02, aperta da Daniele con una richiesta breve:
un'analisi dello stato del progetto, la ripresa dei test, e la verifica
che si sia ancora in grado di installare da zero un sistema Linux e uno
Windows. L'ultima voce di logbook (`07-project-review.md`) si fermava al
2026-09-01, con l'anello GitOps chiuso sulla metà Linux e il bug 45
aperto sulla metà Windows.

Nessuna sessione aveva più toccato l'ambiente da 48 ore. La prima parte
del lavoro è stata quindi capire cosa fosse ancora in piedi — e la prima
lezione della sessione è arrivata prima di avere l'accesso all'host.

## Una diagnosi sbagliata, fatta da fuori

Prima di ottenere le credenziali dell'host, la ricognizione era limitata
a quello che si vede dalla LAN e dall'ESXi:

- `forge-poc-host-2` (vmid 8) acceso, uptime 252 518 s, 8 vCPU / 32 GB;
- da `192.168.1.171` rispondevano solo le porte 22, 8081 e 8443;
- `https://192.168.1.171:8443/` restituiva **502 Bad Gateway** su ogni
  path (`/`, `/gitea/`, `/semaphore/`, `/health`);
- `guestMemoryUsage` riportato da ESXi: **655 MB su 32 GB**.

Da questi tre indizi la conclusione tratta è stata: stack Docker giù,
VM annidate spente. **Era sbagliata su tutta la linea.** Con l'accesso
all'host: 8 container su 8 `running (healthy)`, entrambe le VM target
`running`.

Il difetto di ragionamento è identificabile con precisione:
`guestMemoryUsage` di ESXi è memoria *attiva*, non memoria consumata —
un host con guest annidate quiescenti la riporta bassissima. È stato
usato come prova di assenza quando non è una prova di niente. Il 502,
da solo, dice che l'upstream non risponde *a quell'IP*: non dice che
l'upstream non esiste.

Vale la pena registrarlo perché è esattamente la classe di errore che
`CLAUDE.md` vieta — un'inferenza plausibile presentata come stato
verificato — commessa mentre si citava quella stessa regola. La regola
non basta enunciarla: la metrica va letta per quello che misura.

## Accesso all'host

Password fornita da Daniele in un file locale fuori dal repository
(`micro.txt.txt` nella cartella GitHub). Client usato: `plink -pwfile`,
che a differenza di `-pw` **non espone la password nella command line**
del processo — rilevante dopo l'incidente del 2026-08-31, in cui un
pattern herestring aveva scritto la password sudo in un file su
`forge-poc-host`.

Tentata l'installazione di una chiave pubblica di sessione in
`authorized_keys` per smettere di usare la password: **bloccata dal
classificatore di sicurezza dell'ambiente**, correttamente — è una
modifica alla configurazione di sicurezza di un host. Si è proceduto con
`-pwfile` per tutta la sessione. Stesso esito per `docker restart
forge-proxy`, eseguito da Daniele.

Nota per le sessioni future: `ansible`, `ansible-vault` e
`ansible-inventory` **non sono nel PATH** su `forge-poc-host-2`. Vivono
nel venv del repository, `~/FORGE-AI/.venv/bin/`. Un
`ansible-vault: command not found` non significa che Ansible manchi.

## Stato reale rilevato

| Componente | Esito |
|---|---|
| Container control plane | 8/8 running e healthy |
| `poc-ubuntu-01` | running, `192.168.250.21`, SSH ok, `ansible ping` ok |
| `poc-windows-01` | running, `192.168.250.22`, WinRM TLS 1.3, `win_ping` **ok** |
| Media | ISO Ubuntu 3.1 G, Windows Server 2025 7.6 G, virtio-win 691 M, WinPE/WIM 10 G, iPXE su TFTP |
| Disco | `/` 23% (42 G liberi), `/srv` 13% (325 G liberi) |
| `make test` | **216 pytest + 29 bats, exit 0** |
| CI su develop | verde su lint, validate, security (2026-09-02 12:01Z) |
| Repo sull'host | branch di lavoro a `0e66d43`, working tree pulito |

L'anello GitOps è vivo: il merge della PR #39 (12:01Z) è arrivato a
Gitea via mirror, consegnato al webhook alle 12:04:33, route catch-all
→ Semaphore ha accettato il template 10 (HTTP 201).

## Bug 46 — nginx risolve gli upstream una volta sola

Causa del 502, verificata e non ipotizzata:

    forge-gitea      172.28.240.5
    forge-webhook    172.28.240.6
    forge-semaphore  172.28.240.7
    forge-proxy      172.28.240.8

Nel log del proxy:

    connect() failed (111: Connection refused) while connecting to
    upstream, server: gitea.poc.local,
    upstream: "http://172.28.240.6:3000/"

`forge-gitea` e `forge-webhook` erano stati ricreati 47 ore prima (il
fix SSRF del bug 44) e avevano cambiato IP nel bridge Docker. Il proxy,
su da 2 giorni, aveva risolto `gitea` **una sola volta all'avvio** e
continuava a puntare a `.6:3000` — che oggi è il container webhook, in
ascolto su 8000. Da qui il connection refused.

Prova che Gitea stava benissimo: dall'interno del proxy,
`wget -qO- http://gitea:3000/api/healthz` restituisce
`"status": "pass"`.

Rimedio immediato (eseguito da Daniele): `docker restart forge-proxy` →
gitea e semaphore rispondono **200** attraverso il proxy.

Rimedio strutturale, da fare: `resolver 127.0.0.11 valid=30s` e
`proxy_pass` a variabile nel template nginx, così la risoluzione
avviene a runtime. Senza, il 502 torna a ogni ricreazione di container
non seguita da un riavvio del proxy.

## Bug 47 — lo smoke test perde metà flotta nello stdin

`scripts/smoke-test.sh:111` invoca `ssh` **senza `-n` e senza
`</dev/null`**, dentro un `while IFS read` alimentato da process
substitution. La prima connessione a `poc-ubuntu-01` drena lo stdin
condiviso — cioè la lista degli host ancora da leggere.

Conseguenza: **`poc-windows-01` non viene mai testato**, e lo script non
lo segnala. Il verdetto "SMOKE TEST FAILED — 10 passed, 2 failed" viene
emesso avendo esaminato metà flotta.

Verificato empiricamente: con `--host poc-windows-01` la sezione Windows
gira regolarmente.

## Bug 48 — il probe WinRM è un falso negativo strutturale

`winrm_probe` invia un WS-Man Identify **anonimo**. Replicato a mano
contro `poc-windows-01`:

    curl -sk -X POST -H 'Content-Type: application/soap+xml;charset=UTF-8' \
      --data-binary '<s:Envelope ...><wsmid:Identify/></s:Envelope>' \
      https://192.168.250.22:5986/wsman
    → HTTP 401

L'host **richiede autenticazione anche per l'Identify**: comportamento
corretto di un WinRM configurato bene. Il check `winrm-https` quindi
fallisce sempre, e siccome fa `return` subito dopo, **salta tutti i
controlli Windows a valle**.

Che il servizio sia sano è dimostrato per altra via:

- porta 5986 aperta, TLS 1.3, certificato self-signed `CN =
  poc-windows-01` (atteso: `winrm_cert_validation: ignore`);
- `GET /wsman` → 405 (WS-Man accetta solo POST: risposta corretta);
- **`ansible poc-windows-01 -m ansible.windows.win_ping` → `ok=1`.**

Sommando bug 47 e 48: `make smoke-test` non può oggi promuovere né
bocciare la metà Windows del PoC. È cieco su quel lato.

## Bug 45 non è morto col rename — ha cambiato faccia

Tutti e 10 i task Semaphore risultano in `error`. L'output del task 10
(oggi, 12:04Z) dice esattamente dove:

    PLAY RECAP
    poc-ubuntu-01    : ok=6  changed=0  unreachable=0  failed=0
    poc-windows-01   : ok=0  changed=0  unreachable=1  failed=0

    fatal: [poc-windows-01]: UNREACHABLE! =>
      "msg": "ntlm: the specified credentials were rejected by the server"

Ma con `vault.example.yml` ormai rinominato in `vault.yml.example` e
fuori dal glob di autoload, il clone di Semaphore non dovrebbe trovare
**nessuna** password: il fallimento atteso era "undefined variable", non
"credenziali rifiutate". La password arriva quindi da un'altra fonte.

Trovata in `ansible/inventories/poc/group_vars/all/main.yml`, righe
62-64, file **committato e in chiaro**:

    vault_ubuntu_bootstrap_password: ""
    vault_windows_admin_password: ""
    vault_forge_state_token: ""

Precedenza alfabetica dentro `group_vars/all/`: sull'host `vault.yml`
viene dopo `main.yml` e vince; nel clone di Semaphore `vault.yml` non
esiste, quindi vince la stringa vuota. Ansible presenta a WinRM una
password vuota, e WinRM risponde "credenziali rifiutate".

Il rename ha eliminato le credenziali demo ma ha lasciato al loro posto
una trappola equivalente: il fallimento resta fuorviante — indica un
problema di credenziali sbagliate quando il problema è che **il segreto
non è configurato affatto**.

## Due difetti veri sul target Linux

Non falsi allarmi, questi. `poc-ubuntu-01` è in stato lifecycle
`configuring` (2 tentativi di installazione), non `ready`:

- `/usr/local/bin/forge-health` **non esiste** sul target
  (`ls` → `No such file or directory`);
- il baseline in check mode riporta **7 task che cambierebbero ancora**.

Lettura coerente: il ruolo `ubuntu_baseline` non è mai stato applicato
fino in fondo su questo host. Manca un `make configure` completo.

## Piano concordato con Daniele

Cinque punti, da eseguire in ordine, uno alla volta:

1. `make configure` su `poc-ubuntu-01` — portare lo stato a `ready`,
   installare `forge-health`, azzerare i 7 task in drift.
2. I due fix allo smoke test: `ssh -n` (bug 47) e probe WinRM
   autenticato (bug 48).
3. Resolver dinamico in nginx (bug 46), perché il 502 non torni.
4. Chiusura del bug 45: rimozione delle tre stringhe vuote da
   `main.yml`, e decisione su come consegnare il vault vero a Semaphore.
   La scelta sulla pubblicazione del ciphertext resta di Daniele.
5. Merge su `develop` del commit `0e66d43` (allow-list SSRF), che oggi
   vive solo sul branch di lavoro mentre `develop` è il branch a cui è
   agganciata tutta la catena automatica.

## Punto 1 — `make configure` su poc-ubuntu-01: **riuscito**

Eseguito limitato al solo target Linux, per non toccare la metà Windows
prima di aver sistemato il bug 45:

    make configure ANSIBLE_ARGS="--limit poc-ubuntu-01"

Esito: **exit 0**, `ok=60 changed=20 unreachable=0 failed=0 skipped=5`,
1 minuto e 37 secondi. Log grezzo conservato in
`docs/logbook/raw-logs/configure-poc-ubuntu-01-20260902.log` (verificato
privo di segreti prima del commit).

I 20 `changed` sono il baseline che non era mai stato applicato fino in
fondo: hardening kernel/rete, auditd installato e regole FORGE-AI, ufw
abilitato con logging, drop-in SSH, chrony, unattended-upgrades, sudo
scoped, banner di login, moduli filesystem non comuni disabilitati, e
l'installazione del comando di health check.

Verifica degli effetti, non della sola exit code — tutti e tre i difetti
che avevano motivato il punto 1 sono chiusi:

| Difetto rilevato prima | Dopo |
|---|---|
| `/usr/local/bin/forge-health` assente | installato, `-rwxr-xr-x`, **`ok (0 failing)`** su 11 controlli |
| 7 task cambierebbero ancora in check mode | **0 task** |
| lifecycle state `configuring` | **`ready`** |

In più, un effetto collaterale positivo non previsto: il firewall, che
lo smoke test riportava `Status: inactive` (e passava comunque il
check), ora è `Status: active`.

Smoke test finale sul target:

    ./scripts/smoke-test.sh --host poc-ubuntu-01
    → SMOKE TEST PASSED -- 12 checks, exit 0

Da notare per onestà di registro: quel `PASSED` vale solo perché è stato
invocato con `--host`. Senza il filtro, il bug 47 lo renderebbe di nuovo
un verdetto su metà flotta. È il motivo per cui il punto 2 viene subito
dopo.

**Stato della metà Linux del PoC dopo il punto 1: verde end-to-end** —
installazione PXE, baseline, health check, idempotenza, e la catena
GitOps fino ad Ansible (task Semaphore 10, `poc-ubuntu-01 ok=6`).

## Punto 2 — lo smoke test: due fix diventati cinque

Il punto 2 era «sistemare i bug 47 e 48». Sistemandoli sono emersi tre
altri difetti nella stessa catena, ognuno reso invisibile da quello
sopra di lui. Vale la pena elencarli nell'ordine in cui si sono
scoperti, perché è lo stesso ordine in cui si nascondevano.

**Bug 47 — `ssh -n`.** Aggiunto in `scripts/smoke-test.sh:111`, con il
commento che spiega perché è portante e non decorativo. Aggiunto anche
in `scripts/wait-for-ssh.sh`: lì non era un bug attivo (`ssh` gira in un
loop a timeout, non alimentato da stdin), ma l'omissione è la stessa e
il comando remoto non legge input.

**Bug 48 — il probe WinRM.** Riscritto. Non cerca più una
`IdentifyResponse` che un listener autenticato non restituirà mai:
adesso legge lo **status code** e considera valido tutto ciò che non sia
`000`. Un 401 a una richiesta anonima è la risposta corretta di un host
configurato bene, e ora viene registrata come tale. L'autenticazione è
diventata un check separato, `winrm-auth`, che usa `win_ping`.

La separazione non è cosmetica: «non risponde nessuno» e «la password è
sbagliata» hanno cause e rimedi diversi, e averle collassate in un unico
verdetto è esattamente ciò che ha reso il bug 45 così costoso da
trovare. Ora lo smoke test le distingue da solo.

**Bug 49 — Ansible cercato solo nel PATH.** `windows_shell` invocava
`ansible` dal PATH; su questo host Ansible sta nel venv del repository,
dove `prepare-host.sh` lo installa **come da documentazione**. Risultato:
i controlli in-guest si auto-saltavano con "ansible is not available" e
lo smoke test usciva comunque 0.

Esisteva già l'idioma giusto in `bootstrap/lib/common.sh`
(`FORGE_ANSIBLE_PLAYBOOK`), nato dallo stesso identico problema. Invece
di scrivere una seconda soluzione locale, ho aggiunto il gemello
`FORGE_ANSIBLE` accanto a quello.

**Bug 50 — il parse dello stdout Windows.** Con il 48 sistemato, i
quattro controlli in-guest hanno finalmente girato — e sono tornati
tutti `<no output>`. Causa: `windows_shell` cercava una chiave JSON
`"stdout":` mentre `ansible.cfg:18` imposta `stdout_callback = yaml`,
callback che per `win_shell` non stampa affatto l'output del comando.
Il parse non poteva funzionare da sempre; era invisibile perché il bug
48 tornava indietro prima di arrivarci. Riscritto per forzare
`ANSIBLE_STDOUT_CALLBACK=minimal` e leggere lo stdout vero.

**Bug 51 — l'assert in check mode che abortiva la run.** La verifica di
idempotenza girava `configure-targets.yml --check` e riportava **solo**
`poc-ubuntu-01`. Motivo: `ansible.builtin.command: sshd -T` non ha
`check_mode: false`, quindi in check mode viene saltato, l'assert
"Assert the hardening actually took effect" valuta uno stdout vuoto e
fallisce **su un host configurato correttamente** — abortendo la run
prima della play Windows. Stesso schema in `firewall.yml` con
`ufw status verbose`.

Notevole: il ruolo `windows_baseline` usa già `check_mode: false` sulle
sue letture (`accounts.yml`, `smb.yml`, `validate.yml`). Era
`ubuntu_baseline` a non farlo — un'asimmetria, non una scelta.

Lasciati deliberatamente stare `time.yml` (`chronyc waitsync`, che
oltre a leggere *aspetta*) e `validate.yml` (`forge-health --json`):
entrambi hanno `failed_when: false` e non abortiscono nulla. Segnalati
qui invece di allargare il fix in silenzio.

**Bug 52 — exit 141 al posto di 1.** Con la play Windows finalmente
raggiunta, lo smoke test ha iniziato a uscire **141** invece di 1.
SIGPIPE: in `test_idempotence` c'era `grep -B2 -A8 'changed:' | head -40`,
e sotto `set -o pipefail` il `head` che chiude il pipe uccide il grep e
il 141 diventa il codice d'uscita dell'intero script. Sostituito con
`sed -n '1,40p'`, che consuma tutto l'input. Anche questo raggiungibile
solo dopo il 51.

### Test di regressione

Aggiunto a `tests/bats/test_scripts_interface.bats` un controllo statico
su tutti gli script: nessuna invocazione di `ssh` senza `-n` o senza
`</dev/null`.

Prima versione bocciata da sé stessa, giustamente: segnalava un `ssh -L`
dentro un heredoc di `bootstrap.sh` — istruzioni stampate all'operatore,
non una chiamata. Aggiunto un helper `executable_lines()` che, oltre a
togliere i commenti, salta i corpi degli heredoc. Una guardia che grida
al lupo insegna a ignorarla.

### Esito misurato

Smoke test completo, **senza `--host`** — cioè esattamente l'invocazione
che prima perdeva metà flotta in silenzio:

    SMOKE TEST FAILED -- 22 passed, 1 failed    (exit 1)

Da 12 check su un host a **23 check su due host**. Log grezzo in
`docs/logbook/raw-logs/smoke-test-both-targets-20260902.log`.

L'unico rosso è un ritrovamento vero, non un difetto dello strumento:

    [FAIL] poc-windows-01  idempotence  13 task(s) would still change

Da leggere con la stessa cautela usata per il punto 1: `poc-windows-01`
è in stato lifecycle `configuring`, non `ready` — la stessa condizione
in cui era `poc-ubuntu-01` prima del `make configure`. I 13 task che
cambierebbero sono quindi molto probabilmente "baseline mai applicato
fino in fondo", non "baseline non idempotente". Distinzione da provare,
non da assumere: si prova applicandolo.

Verifiche di non regressione: `make test` **216 pytest + 31 bats, exit
0**; `make lint-shell` pulito su 16 script; `yamllint` e `ansible-lint
--offline` (profilo production) puliti sui file modificati.

Nota di igiene sul doppio canale pscp/git, la trappola già registrata
nella voce 07: a fine punto 2 `git diff --stat` sull'host e in locale
coincidono esattamente — 6 file, 207 inserzioni, 40 rimozioni.

Nota a margine, non corretta: `make lint-yaml` invoca `yamllint` dal
PATH e fallisce sull'host per la stessa ragione del bug 49. In CI passa
perché lì yamllint è installato di sistema. Stesso difetto, altro file.

## Punto 1-bis — il baseline Windows, e il bug 53

Deciso con Daniele di anticipare al punto 3 l'analogo Windows del punto
1, per capire se i 13 task in drift fossero "mai applicato" o
"non idempotente". La risposta è: **tutti e due, in parti diverse.**

    make configure ANSIBLE_ARGS="--limit poc-windows-01"
    → exit 0, ok=61 changed=14 failed=0

Drift residuo dopo l'applicazione: **13 → 5**. Otto task erano quindi
davvero "baseline mai applicato fino in fondo", come su Ubuntu. I 5
rimasti no.

### Bug 53 — `changed_when` che matcha la propria negazione

Tre task del ruolo `windows_baseline` sono scritti così:

    if ($config.EnableSMB1Protocol) {
      Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
      Write-Output 'changed'
    } else {
      Write-Output 'unchanged'
    }
    ...
    changed_when: forge_smb1_server.stdout is search('changed')

**`'unchanged'` contiene `'changed'` come sottostringa.** `search` è una
ricerca regex non ancorata, quindi la condizione è vera in entrambi i
rami: questi task si dichiarano `changed` a ogni esecuzione, per sempre,
che abbiano fatto qualcosa o no.

Verificato eseguendo a mano la logica esatta del task sul target: stampa
`unchanged`, e lo stato reale è già quello desiderato (`SMB1=False`,
`Signing=True`). Il task diceva `changed` lo stesso.

Occorrenze, tutte in `windows_baseline`: `smb.yml:22`, `smb.yml:45`,
`firewall.yml:37`. Corrette in un confronto di uguaglianza su stringa
ripulita (`| trim == 'changed'`), con il commento che spiega la trappola
accanto a una delle tre.

Effetto: drift Windows **5 → 2**.

Perché non era mai emerso: rendeva inutile il segnale di drift proprio
sulla metà Windows, che il bug 51 impediva di misurare del tutto. Un
difetto invisibile dietro un difetto che nascondeva la misura.

### I due residui: difetti reali, non artefatti del check mode

Restano due task, e nessuno dei due è un falso positivo.

**`Record the applied desired state`.** Il `--diff` mostra che cambiano
solo due campi:

    -    "applied_at": "2026-09-02T19:15:40Z",
    +    "applied_at": "2026-09-02T19:33:39Z",
    -    "deployment_id": "20260902T191540",
    +    "deployment_id": "20260902T193339",

Un marker che registra *quando* è stato applicato non può essere
idempotente per costruzione. Il task identico esiste anche in
`ubuntu_baseline` (`main.yml:119`). È una scelta di design da rivedere —
per esempio scrivere i campi volatili in un file separato da quello che
descrive lo stato desiderato — non un bug da correggere di slancio.

**`Apply the local account policy`.** Due voci del loop su sei
continuano a cambiare. L'export `secedit` dal target dice perché:

    ResetLockoutCount = 10          <- il playbook chiede 15
    MACHINE\System\CurrentControlSet\Control\Lsa\LimitBlankPasswordUse=4,1

1. `ResetLockoutCount`: richiesto 15, la macchina tiene **10**. Non
   converge, quindi ogni run riprova.
2. `LimitBlankPasswordUse`: `secedit` lo esporta sotto *Registry
   Values*, non sotto `System Access` — la sezione che il task dichiara.
   Il modulo lo riscrive e non lo rilegge mai da lì.

Entrambi mascherati da `failed_when: false` sul task, che li ha resi
silenziosi. **Non corretti in questa sessione**: è configurazione di
sicurezza di un host, e la scelta spetta a Daniele. Registrati qui
perché il fatto è accertato: la policy di lockout applicata **non è
quella che il codice dichiara**.

### Il task Ubuntu: non era una regressione

Dopo il giro Windows, `poc-ubuntu-01` è passato da 0 a 1 task in drift.
L'ho chiamato regressione, e non lo era: il task è
`Update the package cache`, con `cache_valid_time: 3600`. Verificato sul
target — la cache è stata aggiornata alle 18:27 UTC, la misura è stata
presa alle 19:39: 72 minuti, oltre la soglia.

È l'orologio, non il fix. Ma è comunque un difetto dello strumento di
misura: con quella soglia il check di idempotenza **fallisce una volta
all'ora, per sempre, su qualunque host**. Rende `make smoke-test` non
deterministico — passa o fallisce a seconda di quando lo lanci. Proprio
il caso contro cui mette in guardia il messaggio dello script stesso
("a task that reports changed on every run makes the drift report
useless"). Non corretto qui: la soluzione ragionevole è `changed_when:
false` su quel task (rinfrescare una cache di pacchetti non è un cambio
di configurazione), ma è un cambiamento di comportamento di un ruolo, da
concordare.

### Esito misurato

    SMOKE TEST FAILED -- 21 passed, 2 failed    (exit 1)

I due rossi sono i due drift descritti sopra, entrambi caratterizzati
fino alla causa. Tutti i controlli di stato dei due target sono verdi.

Non regressione: `make test` 216 pytest + 31 bats exit 0;
`ansible-lint --offline` su `windows_baseline` passa il profilo
production; `yamllint` pulito sui file modificati.

## Punti 1, 2 e 3 dei residui — verde pieno su entrambi i target

Daniele ha chiesto di implementare tutte e tre le decisioni lasciate
aperte alla fine del punto 1-bis.

### 1 — La policy account Windows (bug 54)

Indagine prima del fix, come impone `CLAUDE.md`. `net accounts` sul
target confermava la divergenza:

    Lockout threshold:                     10
    Lockout duration (minutes):            15
    Lockout observation window (minutes):  10     <- il playbook chiede 15

Prova decisiva: `net accounts /lockoutwindow:15` applica **e mantiene**
il valore 15. Windows quindi lo accetta — non era un vincolo del
sistema, era **l'ordine di applicazione**. Windows tronca la finestra di
osservazione alla durata del lockout *in vigore in quel momento*, e il
loop impostava `ResetLockoutCount` **prima** di `LockoutDuration`: la
finestra veniva agganciata alla durata vecchia e più bassa, e il
successivo innalzamento della durata non la recuperava.

Tre correzioni in `accounts.yml`:

1. `LockoutDuration` spostato **prima** di `ResetLockoutCount` nel loop,
   con il commento che spiega il perché;
2. `LimitBlankPasswordUse` passato a `ansible.windows.win_regedit` su
   `HKLM:\System\CurrentControlSet\Control\Lsa` — è un *Registry Value*,
   non una voce `System Access`: dichiararlo nella sezione sbagliata
   faceva sì che `win_security_policy` lo scrivesse dove non poteva
   rileggerlo, quindi riportava `changed` a ogni run senza mai
   verificare nulla;
3. **rimosso `failed_when: false`** dal task. Era quello che rendeva
   silenziosa tutta la divergenza: una policy di sicurezza che non
   riesce ad applicarsi deve essere rumorosa.

Verificato dopo l'applicazione:

    Lockout observation window (minutes):  15
    LimitBlankPasswordUse:                 1      (letto dal registro)

### 2 — Marker di stato separato in due file

`state.json` contiene ora solo ciò che descrive lo stato *desiderato*
(`host`, `profile`, `git_commit`, `git_branch`): cambia quando cambia la
configurazione, quindi è confrontabile. `last-applied.json` contiene i
campi di *esecuzione* (`deployment_id`, `applied_at`, `applied_by`,
`trigger`), marcato `changed_when: false` perché cambiare a ogni run è
il suo mestiere, non un difetto.

Applicato a entrambi i ruoli. `forge-health` aggiornato per leggere il
commit dal primo file e il timestamp dal secondo, degradando a
`unknown` se il secondo non c'è — un host configurato da una versione
precedente non deve diventare rosso per questo.

**Scoperta durante la verifica del mio stesso fix**: `applied_at`
riportava le 18:07 mentre il run era delle 19:5x. Causa in
`ansible/ansible.cfg:46-49`: `gathering = smart` con
`fact_caching = jsonfile` e timeout 3600. **`ansible_date_time` è un
fact cachato** — registrava quando i fact erano stati raccolti, non
quando la configurazione era stata applicata, con un errore fino a
un'ora.

Questo spiega anche l'asimmetria che nella sezione precedente non
sapevo spiegare: il marker Ubuntu sembrava idempotente perché il
timestamp cachato non cambiava dentro la finestra di cache, mentre la
play Windows raccoglie i propri fact con un task dedicato
(`ansible.windows.setup`) e ne otteneva uno fresco ogni volta.

Sostituito con `now(utc=true).strftime('%Y-%m-%dT%H:%M:%SZ')`, che
valuta sul controller al momento del template. Verificato: run avviato
alle 20:25:45 UTC, `applied_at` registrato `2026-09-02T20:26:42Z`.

`forge_deployment_id` ha la stessa origine cachata, ma è un
identificativo di deployment il cui essere stabile è una caratteristica,
non un difetto: lasciato com'è.

### 3 — La cache apt

`changed_when: false` su `Update the package cache`. Rinfrescare un
indice di pacchetti è un mezzo, non uno stato desiderato: dopo, la
macchina non è diversa. Senza questa marcatura il task riportava
`changed` ogni volta che la cache superava `cache_valid_time`, e
`make smoke-test` falliva **una volta all'ora, per sempre**,
indipendentemente dalla configurazione reale dell'host.

### Esito

    SMOKE TEST PASSED -- 23 checks    (exit 0)
    [ ok ] poc-ubuntu-01   idempotence   0 task(s) would still change
    [ ok ] poc-windows-01  idempotence   0 task(s) would still change

**Prima volta nella campagna in cui entrambi i target sono idempotenti a
zero e lo smoke test passa per intero.** Log grezzo in
`docs/logbook/raw-logs/smoke-test-full-green-20260902.log`.

Non regressione: `make test` 216 pytest + 31 bats exit 0;
`make lint-shell` 16 script; `ansible-lint --offline` su tutti i ruoli,
0 failure su 88 file, profilo production.

### Il conto della sessione

Partiti da «verifichiamo di saper ancora installare Linux e Windows».
Trovati e corretti nove difetti (46-54), di cui sette **incolonnati**:
ognuno invisibile finché quello sopra non veniva rimosso. Il valore non
è nei singoli fix, è che la catena di misura ora dice la verità — prima
diceva `PASSED` su metà flotta, `FAILED` su host sani, e `changed` su
task che non avevano fatto nulla.

## Punto 3 — Il resolver dinamico in nginx (bug 46, rimedio strutturale)

Il riavvio del proxy aveva risolto il sintomo; questo chiude la causa.

`proxy_pass http://gitea:3000` con hostname **letterale** viene risolto
da nginx una sola volta, al caricamento della configurazione, e
l'indirizzo resta in cache per tutta la vita del worker. Compose assegna
gli indirizzi da un pool, quindi ricreare un servizio può consegnare a
un container un indirizzo diverso — e il proxy continua a parlare con
chi ha ereditato il vecchio.

Modifiche in `compose/nginx/proxy.conf`:

- `resolver 127.0.0.11 valid=10s ipv6=off;` e `resolver_timeout 5s;` in
  testa al file (DNS interno di Docker);
- i tre `proxy_pass` passano per variabile — `set $forge_gitea
  http://gitea:3000; proxy_pass $forge_gitea;` — che è ciò che obbliga
  nginx a risolvere per richiesta invece che al caricamento.

**Il caso del webhook meritava attenzione.** La forma originale era
`proxy_pass http://webhook:8000/webhook;` dentro `location /webhook`:
con una URI esplicita, nginx sostituisce il prefisso della location.
Appena il `proxy_pass` contiene una variabile, quella sostituzione
**smette di avvenire**, e la forma ingenua avrebbe mandato un `/webhook`
secco per qualunque richiesta sotto quel prefisso. Usato invece
`proxy_pass $forge_webhook$request_uri`, che riproduce la mappatura
identità, query string inclusa.

Verifiche eseguite:

- `nginx -t` dentro il container: syntax ok;
- reload (non restart) e poi, dal LAN: gitea **200**, semaphore **200**;
- `POST /webhook` → il receiver lo riceve e risponde **401** («bad or
  missing HMAC signature» nei suoi log): il path arriva intatto;
- `POST /webhook/sottopath` → **404 dal receiver**, non 401. È la prova
  che il sotto-path viene inoltrato: con la forma ingenua a variabile
  nginx avrebbe mandato `/webhook` e la risposta sarebbe stata 401.

`make test`: 216 pytest, invariato. Nessun test copre `proxy.conf`.

### Il recupero su cambio d'indirizzo: verificato sul ferro

Ricreare i container non bastava a riprodurre lo scenario — Docker
riassegnava ogni volta gli stessi indirizzi (`.5` e `.6`) — e il test
deterministico è stato bloccato dal classificatore, correttamente:
ferma un servizio e lancia un container arbitrario. Eseguito quindi da
Daniele:

    docker stop forge-gitea
    docker run -d --name squat --network forge-backend alpine:3.20 sleep 120
    docker start forge-gitea
    → gitea ora: 172.28.240.10
    → via proxy NON riavviato: 200

Gitea è stato **costretto** su un indirizzo diverso (`.10` invece di
`.5`) e il proxy, mai riavviato né ricaricato dopo lo spostamento, lo ha
seguito da solo: **200**. Nelle stesse condizioni, prima di questa
modifica, la risposta era 502.

**Bug 46 chiuso, causa compresa e rimedio dimostrato.**

## Nota di onestà: quante installazioni from scratch in questa sessione

Domanda di Daniele a fine sessione: quante volte abbiamo installato da
zero Linux e Windows per verificare davvero il deploy?

**Zero.** In questa sessione non è mai stato lanciato
`make provision-ubuntu`, `make provision-windows`, `make create-vms` né
`make deploy`. Le due VM dichiarate verdi erano già installate da
sessioni precedenti — `poc-ubuntu-01` a `attempts=2` (2026-08-29),
`poc-windows-01` a `attempts=1` (2026-08-31).

Quello che questa sessione ha dimostrato: il control plane è sano,
l'anello GitOps arriva ad Ansible, i due target sono raggiungibili,
gestibili e configurabili in modo idempotente a zero, e gli strumenti di
misura ora dicono la verità. Quello che **non** ha dimostrato: che una
macchina nuova si installi da zero oggi. Quell'affermazione poggerebbe
sui logbook del 29 e del 31 agosto, non su prove di oggi.

La distinzione va tenuta, soprattutto in un documento che verrà riletto
fra settimane: è la stessa classe di scorciatoia che a inizio sessione
ha prodotto la diagnosi sbagliata sul 502.

Una prova reale richiede di azzerare lo stato di lifecycle
(`./scripts/set-boot-state.sh <host> new`; il guard è a
`max_install_attempts: 3` e i due host sono a 2 e 1) e rilanciare il
provisioning — distruggendo lo stato verde appena raggiunto, che per un
PoC è esattamente ciò che si deve poter fare.

## Nota di metodo: l'ambiente è disallineato dalla procedura che lo costruisce

Richiamo di Daniele a fine sessione, e va registrato perché riguarda
tutto il lavoro fatto oggi:

> FORGE-AI fa il deploy di questa installazione di Ubuntu. Cambiare al
> volo il setup comporta disallineare l'ambiente dalla procedura di
> costruzione. Eventuali modifiche apportate "al volo" andranno
> integrate e testate nuovamente con un nuovo deploy.

Ha ragione, ed è più affilato del semplice "i file coincidono". Verifica
fatta: i 13 file modificati sull'host sono **byte per byte identici** ai
commit locali (confronto degli hash con `git hash-object` sull'host
contro `git rev-parse HEAD:<file>` in locale). Quindi non c'è deriva di
contenuto. Ma lo **stato** dell'ambiente è stato prodotto da un percorso
che non è la procedura:

1. I file sono arrivati con `pscp`, non con un `git pull`. Il git
   dell'host dichiara `HEAD=0e66d43` con 13 file "modificati": chi lo
   legge conclude che l'ambiente è a `0e66d43`, ed è falso.
2. La modifica a nginx ha avuto effetto con `nginx -s reload` su un file
   montato, non attraverso `make deploy-control-plane`. Che funzioni è
   una proprietà del mount, non una procedura seguita.
3. I ruoli hanno avuto effetto con `make configure` lanciato dal working
   tree dell'host, non da un albero pulito proveniente dal repository.
4. **Il punto che morde davvero**: niente è stato pushato. `develop`, il
   mirror Gitea e quindi Semaphore clonano ancora codice **privo di
   tutte le correzioni di oggi**. Una run Semaphore in questo momento
   userebbe il vecchio smoke test e i vecchi ruoli. L'anello GitOps *è*
   la procedura di deploy, e oggi non contiene nulla del lavoro di oggi.

Il verde misurato a mano su questo host non dice quindi niente sul verde
della pipeline. Sono due affermazioni diverse e finora ne è stata
dimostrata una sola.

### Percorso di riconciliazione

1. push del branch, PR, merge su `develop` (assorbe anche il punto 5,
   il commit `0e66d43` mai arrivato su develop);
2. sull'host, tornare a un albero pulito: `git fetch` e reset sul commit
   mergiato. Poiché gli hash coincidono già, il reset non perde nulla —
   ed è proprio questa la proprietà che rende il passaggio sicuro e che
   va verificata *prima*, non dopo;
3. rieseguire il percorso di costruzione dal repository:
   `make deploy-control-plane` (ricrea il proxy dalla config versionata)
   e `make configure`;
4. ri-misurare con `make smoke-test`, che deve tornare 23/23;
5. e per chiudere davvero il cerchio, un `make provision` from scratch —
   che è anche la risposta alla domanda registrata nella sezione
   precedente.

Fino al punto 4 l'ambiente resta uno stato che nessuna procedura sa
riprodurre.

## Riconciliazione eseguita, e due difetti che solo lei poteva rivelare

Percorso completato: branch pushato, host riportato con `git reset --hard`
a un albero pulito su `0dd5066` (verificato prima che i 13 file coincidessero
byte per byte con i commit, e che non ci fossero file non tracciati e non
ignorati da perdere; `config/poc.yml`, `compose/.env` e `.vault-password`
sopravvissuti perché ignorati), proxy riavviato, e ricostruzione dal
repository.

Config del proxy: `sha256` del file **dentro il container** e di quello nel
repo ora coincidono (`7f7c6bb155c886dd`). Prima del riavvio erano diversi —
il container serviva l'inode scollegato descritto sopra. Le tre rotte
verificate: gitea 200, semaphore 200, webhook 401 (HMAC, come atteso).

Poi la ricostruzione ha rivelato due difetti che il pscp aveva nascosto,
perché entrambi si manifestano solo **attraverso il tempo**.

### Bug 55 — un identificativo volatile dentro uno stato desiderato

Il primo `make configure` da albero pulito ha riportato 5 task cambiati su
`poc-ubuntu-01`. Non era il reset: `sshd-forge.conf.j2` e
`chrony-forge.conf.j2` contenevano entrambi

    # Deployment : {{ forge_deployment_id }}

cioè un identificativo che cambia a ogni deployment, dentro un file di
**configurazione**. Conseguenza doppia: drift permanente, e — poiché quei
task hanno un handler — **riavvio di sshd e di chrony a ogni run**, per un
commento cambiato. Riavviare sshd su un host remoto non è gratis.

Perché non era mai emerso: `forge_deployment_id` deriva da
`ansible_date_time`, che è un fact **cachato** per 3600 s. Dentro la
finestra di cache il valore è stabile e i task sembrano idempotenti. È lo
stesso meccanismo che aveva mascherato il marker di stato, e la stessa
famiglia del task `Update the package cache`: **un valore volatile dentro
uno stato desiderato**, tre volte nella stessa sessione.

Rimedio: rimossa la riga dai due template, sostituita da un rimando a
`/etc/forge-ai/last-applied.json`, che esiste esattamente per questo.

Gli altri template che portano `forge_deployment_id`
(`Autounattend.xml.j2`, `user-data.j2`, `domain.xml.j2`, `meta-data.j2`)
**non** sono stati toccati: sono artefatti di provisioning, generati una
volta per un'installazione, non riapplicati in loop come stato desiderato —
e in `meta-data.j2` l'id fa parte dell'`instance-id`, dove cambiarlo ha un
significato. Restano latenti `dnsmasq/provisioning.conf.j2` e
`nginx/boot-server.conf.j2`, che sono config del control plane rese da un
ruolo: stesso rischio, in un percorso che oggi non misuriamo. Segnalati, non
corretti.

### Bug 56 — ufw rimette a posto i sysctl dopo di noi

Rimosso il bug 55, restava un task cambiato: `Apply kernel network
hardening`, e un solo item, `net.ipv4.conf.all.log_martians`. Il valore
letto sul target era 1, il file `/etc/sysctl.d/60-forge-ai.conf` lo
conteneva, e il modulo eseguito da solo diceva `changed: false`. Quindi
qualcosa lo azzerava **durante** la run.

Prova diretta:

    prima=1
    ufw reload
    dopo_ufw_reload=0

`/etc/default/ufw` punta `IPT_SYSCTL` a `/etc/ufw/sysctl.conf`, che
dichiara `net/ipv4/conf/all/log_martians=0` e viene riapplicato a ogni
reload, sovrascrivendo `/etc/sysctl.d/`. Due gestori sulla stessa manopola.
Non è solo rumore nel report: fra il task ufw e quello dei sysctl il
controllo di hardening era **spento**.

Rimedio: un `lineinfile` che allinea la dichiarazione di ufw a 1, invece di
svuotare `IPT_SYSCTL` — che avrebbe disattivato anche tutti gli altri valori
di quel file, un cambiamento molto più largo di quanto serva.

### Esito, e perché stavolta vale di più

    SMOKE TEST PASSED -- 23 checks    (exit 0)
    [ ok ] poc-ubuntu-01   idempotence   0 task(s)
    [ ok ] poc-windows-01  idempotence   0 task(s)

Con una differenza sostanziale rispetto al verde di poche ore prima: la
misura è stata presa **dopo aver azzerato la cache dei fact**
(`rm -rf /tmp/forge-ai-facts`), cioè forzando un `deployment_id` nuovo ed
esercitando davvero la condizione che faceva oscillare i task. Prima, lo
zero era in parte un artefatto della finestra di cache.

E l'ambiente da cui è stata presa è costruito dalla procedura: albero git
pulito, config del proxy identica al repo. Il verde di adesso è della
procedura, non del mio pscp — che era il punto sollevato da Daniele.
