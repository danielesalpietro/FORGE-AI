# 03 — Fase 5: bootstrap del control plane, cinque bug reali mai emersi prima

Questi playbook non erano mai stati eseguiti in nessun ambiente reale
prima di stanotte (2026-08-28) — ogni bug qui sotto era latente nel
repository, non introdotto da questa sessione, e riemergerebbe
identico in qualunque altro ambiente che eseguisse `bootstrap.sh` per
la prima volta. Tutti trovati eseguendo `bootstrap.sh` ripetutamente,
verificando l'`EXIT_CODE` reale catturato esplicitamente (non il
riepilogo automatico del task, già dimostrato inaffidabile — vedi voce
02) e leggendo il log completo di ogni fallimento prima di correggere.

## Bug 1 — `src:` relativo al ruolo non trova la directory condivisa `ansible/templates/`

**Sintomo**: Stage 4/7 (rete) fallisce: `Could not find or access
'libvirt/network.xml.j2'`.

**Causa**: `ansible.builtin.template` con un `src:` relativo al ruolo
(es. `libvirt/network.xml.j2`) cerca solo dentro il ruolo stesso e la
`templates/` del playbook — mai la directory condivisa
`ansible/templates/` dove vive davvero il file. Solo il ruolo
`ubuntu_baseline` ha una propria `templates/` locale; **altri 8 ruoli**
(`windows_winpe`, `ipxe_menu`, `windows_unattend`, `reporting`,
`pxe_server`, `drift_detection`, `ubuntu_autoinstall`, `vm_lifecycle`,
oltre a `libvirt_network`) avevano lo stesso problema — verificato
confrontando ogni `src:` di tipo `ansible.builtin.template` nel
repository (`grep` mirato) contro l'elenco reale dei file sotto
`ansible/templates/`.

**Primo tentativo di correzione**: `src: "{{ playbook_dir }}/../templates/<path>"`.
Funziona a runtime ma **viola la regola `no-relative-paths` di
`ansible-lint`** (profilo `production`, 19 violazioni) — un `..`
letterale nel `src:` non è ammesso.

**Correzione definitiva**: una variabile unica in
`ansible/inventories/poc/group_vars/all/main.yml`:

    forge_shared_templates_dir: "{{ playbook_dir | dirname }}/templates"

(`dirname` invece di un `..` letterale — stesso risultato, supera il
controllo testuale di `ansible-lint`). Ogni ruolo referenzia questa
variabile invece di scrivere il percorso a mano.

**Commit**: `ccf46ed` (prima versione con `../`), `26832ae` (versione
definitiva con `dirname`, dopo che `make lint` ha bocciato la prima).

**Stato**: risolto e verificato (`make lint` -> `Lint clean`).

## Bug 2 — Il ruolo `libvirt_host` non viene mai chiamato da nessuna parte

**Sintomo**: risolto il Bug 1, Stage 4/7 fallisce di nuovo:
`Destination directory /srv/forge-ai/config does not exist`.

**Causa**: il ruolo `libvirt_host` crea proprio quell'albero di
directory (`artifacts_dir`, `http_root`, `config/`, `state_dir`,
storage pool libvirt) — ma **nessun playbook, `bootstrap.sh` o target
del Makefile lo richiama mai**. Un ruolo scritto e mai collegato alla
pipeline reale. Verificato con `grep -rn libvirt_host` su
`Makefile`/`site.yml`/`bootstrap.sh`: zero risultati fuori dal ruolo
stesso.

**Correzione**: aggiunto come ruolo in `playbooks/create-provisioning-network.yml`,
prima di `libvirt_network` (idempotente per progetto, sicuro da
rieseguire). Copre l'intera pipeline per un run completo di
`bootstrap.sh`, dato che lo stage rete gira sempre prima di
control-plane/gitops/verify. **Non risolto**: un `make create-vms`
isolato, mai preceduto da un bootstrap completo, colpirebbe lo stesso
problema — annotato come follow-up nell'issue #2, non corretto ora per
restare nello scope di quanto blocca stanotte.

**Commit**: `eec94c6`.

**Stato**: risolto.

## Bug 3 — Il pool libvirt punta a una directory mai creata

**Sintomo**: risolto il Bug 2, Stage 4/7 fallisce di nuovo:
`cannot open directory '/srv/forge-ai/images': No such file or directory`
allo start del pool (non alla `define`, che con solo XML non richiede
che la directory esista già).

**Causa**: `storage.libvirt_pool_path` è stato impostato a
`/srv/forge-ai/images` in `config/poc.yml` (invece del default
`/var/lib/libvirt/images`, creato automaticamente dal pacchetto
`libvirt-daemon` — motivo per cui questo problema non emerge mai con la
configurazione di default). Il loop di creazione directory del ruolo
`libvirt_host` non includeva `storage.libvirt_pool_path` come voce.

**Correzione**: aggiunta `{ path: "{{ storage.libvirt_pool_path }}" }`
al loop `Create the FORGE-AI directory tree`.

**Commit**: `f2ec187`.

**Stato**: risolto.

## Bug 4 — `jmespath` mancante per il filtro `json_query`

**Sintomo**: risolto il Bug 3, Stage 4/7 fallisce di nuovo (più avanti
stavolta — rete creata, bridge su, gateway assegnato):
`The filter plugin 'community.general.json_query' failed: You need to
install "jmespath" prior to running json_query filter`.

**Causa**: `ansible/requirements-python.txt` non elenca `jmespath`,
mai installato nel venv. Verificato con `grep -r jmespath` sull'intero
repository: zero risultati prima della correzione.

**Correzione**: aggiunta `jmespath>=1.0,<2` a
`ansible/requirements-python.txt`.

**Effetto collaterale trovato durante l'installazione**: `pip install
jmespath` nel venv esistente ha dato `Permission denied` —
`.venv/lib/python3.12/site-packages` risultava di proprietà di
`root:root` invece di `dsalpietro`. Causa più probabile: un'esecuzione
precedente di `bootstrap.sh` sotto `sudo -S -E env PATH=...` (necessaria
per i privilegi di libvirt/Docker/`/srv`) ha scritto nel venv condiviso
mentre girava come root. **Non ancora risolto strutturalmente** — ogni
run sotto sudo rischia di far accadere di nuovo lo stesso; per stanotte
corretto con `sudo chown -R dsalpietro:dsalpietro .venv`. Da investigare
come follow-up: separare i privilegi in modo che l'esecuzione root non
tocchi mai il venv dell'operatore.

**Commit**: `5085af0`.

**Stato**: risolto per questo run; la causa della proprietà root del
venv resta da investigare (aggiunta all'issue #2).

## Bug 5 — Il probe DHCP resta bloccato all'infinito, timeout mai applicato

**Sintomo**: risolto il Bug 4, Stage 4/7 arriva fino al task
`prerequisite_validation : Listen for foreign DHCP traffic on the
provisioning bridge` e non torna più — **13+ minuti di attesa**, notato
perché Daniele ha chiesto esplicitamente lo stato dei lavori.

**Causa**: il comando usava
`tcpdump -c 5 -W 1 -G {{ prereq_dhcp_probe_timeout }} ...` (timeout
configurato: 8 secondi) per limitare la durata. **`-G`/`-W` di tcpdump
governano la rotazione di un file di output (`-w`), che qui non esiste
— senza `-w` non fanno nulla.** Il comando restava quindi bloccato in
attesa di `-c 5` pacchetti DHCP che su un bridge appena creato, senza
nessun client collegato, non arrivano mai. Non un caso limite: un bug
di logica del comando, che si sarebbe ripresentato identico ad ogni
prima esecuzione su qualunque host.

**Perché non era mai emerso prima**: `check-prerequisites.sh` esegue lo
stesso probe, ma sempre *prima* che il bridge esista (il ramo "bridge
non ancora creato" evita il probe reale). Stanotte è stata la prima
volta che questo controllo girava con il bridge già attivo.

**Verifica prima di intervenire**: controllato `ps aux` sull'host per
confermare che il processo fosse vivo ma bloccato (CPU ~0%, non in
loop), non semplicemente lento; controllato il default di
`prereq_dhcp_probe_timeout` (8s) contro il tempo reale trascorso
(13+ minuti) per escludere che fosse solo un timeout configurato
troppo alto.

**Intervento immediato**: terminati a mano i processi bloccati
(`tcpdump`, la catena `bootstrap.sh`/`ansible-playbook`) via `kill -9`
sui PID specifici, dopo un primo tentativo con `pkill` per pattern che
non ha dato conferma esplicita.

**Correzione applicata**: sostituito `-c 5 -W 1 -G {{ ... }}` con
`timeout {{ prereq_dhcp_probe_timeout }}s tcpdump -c 5 --immediate-mode ...`
— `timeout` invia SIGTERM alla vera scadenza; tcpdump esce pulito e
stampa quanto già catturato in modalità immediata. `failed_when: false`
tollera già il codice di uscita non-zero di un `timeout` che ha dovuto
segnalare il processo.

**Commit**: `d8acab0`.

**Stato**: risolto — confermato nel run successivo, lo stage rete è
passato pulito (probe DHCP concluso in 8.46s, esattamente il timeout
configurato).

## Bug 6 — `command -v` via il modulo `command` di Ansible: non trova mai nulla

**Sintomo**: risolti i Bug 1-5, arrivati per la prima volta allo
Stage 5/7 (control plane), fallisce subito:
`[ERROR] required-commands: not on PATH: virsh, virt-install, qemu-img,
dnsmasq, docker, curl, jq, sha256sum -- run ./bootstrap/prepare-host.sh`
— nonostante tutti questi comandi fossero già stati confermati presenti
da `check-prerequisites.sh` (Fase 4).

**Causa**: `ansible.builtin.command: "command -v {{ item }}"` —
`command` è un builtin della shell (bash/dash), non un eseguibile
autonomo; il modulo `command` di Ansible non passa mai per una shell,
quindi tenta di eseguire un binario `command` che non esiste. Fallisce
**sempre**, per ogni voce, su qualunque host — non un problema di
questo ambiente. `failed_when: false` mascherava ogni fallimento
per-voce come "ok" nell'output del task; solo il controllo successivo
sul codice di uscita (`rc`) ha fatto emergere il problema reale. Un
ruolo Ansible-nativo (`prerequisite_validation`) mai esercitato prima
d'ora — diverso dallo script bash `check-prerequisites.sh` di Fase 4,
motivo per cui i due controlli hanno dato esiti opposti sugli stessi
comandi.

**Correzione**: sostituito `command -v {{ item }}` con `which {{ item }}`
(`which` è un eseguibile reale, verificato presente:
`/usr/bin/which`).

**Commit**: `be5a934`.

**Stato**: risolto.

## Bug 7 — Due riferimenti a `ansible/templates/` sfuggiti al primo giro (Bug 1)

**Sintomo**: risolto il Bug 6, Stage 5/7 fallisce di nuovo:
`Could not find or access 'nginx/boot-server.conf.j2'`.

**Causa**: stessa classe del Bug 1, due varianti che la ricerca
originale (`grep "ansible.builtin.template:" ansible/roles`) non
copriva:
1. Un task `ansible.builtin.template` scritto **direttamente in un
   playbook** (`ansible/playbooks/bootstrap-control-plane.yml`), non
   dentro un ruolo — la ricerca era scoped solo a `ansible/roles`.
2. Un `lookup('ansible.builtin.template', 'semaphore/environment.json.j2')`
   in `ansible/roles/semaphore_config/tasks/repository.yml` — un
   lookup plugin, non un task `ansible.builtin.template:`, quindi
   invisibile alla stessa ricerca testuale.

**Correzione**: stesso pattern (`forge_shared_templates_dir`) applicato
a entrambi. Fatta una ricerca più ampia dopo la correzione (ogni
riferimento a `.j2` in `ansible/roles` e `ansible/playbooks`,
indipendentemente dal modulo/meccanismo usato) per confermare che non
restassero altri casi — nessuno trovato.

**Commit**: `ca28485`.

**Stato**: risolto.

## Bug 8 — Le verifiche di readiness di Gitea/Semaphore puntano alla porta sbagliata

**Sintomo**: risolto il Bug 7, Stage 5/7 (Docker Compose) completa
finalmente per intero (3m17s) — la prima volta che arriva così lontano.
Passa allo Stage 6/7 (Gitea e Semaphore) e fallisce:
`[FAIL] Gitea did not become ready within 180s`.

**Verifica prima di intervenire**: `docker compose ps` mostrava
`forge-gitea` già "Up 3 minutes (healthy)" — l'healthcheck **interno**
al container passava, e i log mostravano risposte 200 OK regolari su
`/api/healthz`. Il servizio funzionava; il controllo di `bootstrap.sh`
verificava qualcosa d'altro.

**Causa**: `stage_gitops` interroga
`http://127.0.0.1:{{ control_plane.gitea_http_port }}` (porta 3000) —
ma quella porta **non è mai pubblicata sull'host**, solo esposta dentro
la rete Docker interna. `docker compose ps` confermato: nessun mapping
`127.0.0.1:X->3000`. L'unico punto di accesso reale dall'host è il
proxy nginx (`compose/nginx/proxy.conf`), che instrada per SNI/Host
header su un'unica porta TLS (8443) verso `gitea:3000` o
`semaphore:3000` internamente. `config/defaults.yml` lo dice
esplicitamente nel commento: "nginx in the compose stack fronts them
with TLS" — il bug era nell'aver ignorato il proprio commento. Lo
stesso problema esisteva identico in `create_semaphore_token()`.

**Correzione**: entrambi i controlli di readiness e
`create_semaphore_token()` ora passano da
`curl --resolve <hostname>:8443:127.0.0.1 -k https://<hostname>:8443/...`
— stessa topologia che il riepilogo finale di `bootstrap.sh` già
suggerisce all'operatore per l'accesso browser, semplicemente mai
applicata ai controlli interni dello script.

**Verifica diretta prima di committare**: `curl --resolve
semaphore.poc.local:8443:127.0.0.1 https://semaphore.poc.local:8443/api/ping`
-> `pong`, riuscito subito. La stessa chiamata per Gitea su
`/api/v1/version` ha dato **403** — bug distinto (vedi sotto), non lo
stesso problema di routing (la rete ora funziona, altrimenti sarebbe
stato "connection refused" come prima, non un 403 con risposta JSON).

**Bug collaterale trovato durante la verifica**: `/api/v1/version` di
Gitea 1.22.6 richiede un utente autenticato
(`{"message":"Only signed in user is allowed to call APIs."}`), quindi
non utilizzabile per un probe di readiness anonimo. Verificato
`/api/healthz` -> `200` senza autenticazione; usato quello al suo
posto.

**Commit**: `783ef42`.

**Stato**: risolto, verificato manualmente con `curl` prima del commit
per entrambi i servizi — confermato nel run successivo ("Gitea is
answering" / "Semaphore is answering" entrambi passati).

## Bug 9 — Le automazioni Ansible di `gitea_config`/`semaphore_config` presumono una porta mai pubblicata

**Sintomo**: risolto il Bug 8, `bootstrap.sh` avanza oltre le due
verifiche bash e arriva a un playbook Ansible dentro Stage 6/7:
`FAILED - RETRYING: [forge-control]: Wait for the Gitea API` per 30
tentativi, poi `Connection refused`.

**Causa**: stesso problema di fondo del Bug 8, ma questa volta dentro
Ansible, non in `bootstrap.sh`. `gitea_api_url` (ruolo `gitea_config`,
9 usi) e `semaphore_api_url` (ruolo `semaphore_config`, 23 usi tra
`main.yml`, `templates.yml`, `repository.yml`, `keys.yml`) sono
entrambi definiti come `http://127.0.0.1:{{ ...http_port }}/...` — ma
né la porta di Gitea (3000) né quella di Semaphore (3001) erano mai
pubblicate sull'host da `compose/docker-compose.yml`. Confermato
leggendo il blocco servizio di entrambi: Gitea pubblica solo la porta
SSH (2222) con un commento esplicito e intenzionale — "HTTP is reached
through the proxy only" — Semaphore non pubblicava nessuna porta.

**Non un errore di battitura**: `GITEA__service__REQUIRE_SIGNIN_VIEW:
"true"` nello stesso file spiega anche il 403 del Bug 8 su
`/api/v1/version` — la scelta di instradare tutto tramite proxy TLS è
reale e voluta, per l'accesso browser/LAN. Il problema è che i ruoli
Ansible che orchestrano lo stack (automazione *interna*, non un
browser esterno) presumevano comunque un accesso diretto via loopback
che non è mai esistito.

**Alternative valutate e scartate**: instradare tutte le 32 chiamate
`ansible.builtin.uri` attraverso il proxy TLS (stesso approccio del Bug
8) avrebbe richiesto: (a) una risoluzione hostname per `gitea.poc.local`/
`semaphore.poc.local` sull'host di controllo — verificato con `getent
hosts`/`cat /etc/hosts`: **non esiste**, nonostante `config/defaults.yml`
dica esplicitamente che sono "expected in /etc/hosts on the KVM host";
(b) `validate_certs: false` aggiunto singolarmente su ognuna delle 32
chiamate. Scartata per l'ampiezza della modifica necessaria a fronte
del tempo disponibile.

**Correzione applicata**: pubblicate entrambe le porte su loopback in
`compose/docker-compose.yml` (`127.0.0.1:3000` per Gitea,
`127.0.0.1:3001` per Semaphore, con override da variabile d'ambiente
come già fatto per le altre porte nello stesso file) — stesso confine
di fiducia del bind loopback già usato dal proxy stesso, nulla diventa
raggiungibile dalla LAN. Nessuna modifica al codice Ansible esistente,
che era già scritto assumendo esattamente questo.

**Stato**: risolto — confermato nel run successivo: connessione
riuscita (niente più "Connection refused"), sostituita da un problema
diverso (Bug 10).

## Bug 10 — Stesso 403 di autenticazione, questa volta nel task Ansible di attesa

**Sintomo**: risolto il Bug 9, il task Ansible `gitea_config : Wait for
the Gitea API` non fallisce più per connessione rifiutata, ma esaurisce
comunque tutti i 30 tentativi (300 secondi) prima di arrendersi con
`Status code was 403 and not [200]: HTTP Error 403: Forbidden`.

**Causa**: identica al bug collaterale già trovato nel Bug 8 — questo
task interroga `{{ gitea_api_url }}/version` (cioè `/api/v1/version`),
che richiede un utente autenticato, mentre nessun token esiste ancora
a questo punto del bootstrap (viene creato solo dopo, da
`create_gitea_token()` in `bootstrap.sh`). Stavolta il bug viveva nel
ruolo Ansible, non nello script bash già corretto.

**Verifica**: `curl http://127.0.0.1:3000/api/healthz` (ora
raggiungibile grazie al Bug 9) -> `{"status":"pass",...}`, nessuna
autenticazione richiesta, nessun campo versione nella risposta.

**Correzione**: separata `gitea_base_url` (senza `/api/v1`) da
`gitea_api_url` in `ansible/roles/gitea_config/defaults/main.yml`; il
task di attesa ora interroga `{{ gitea_base_url }}/api/healthz` e
riporta lo stato di salute invece del numero di versione (che
`/healthz` non fornisce).

**Commit**: `8284008`.

**Stato**: risolto — confermato: sia "Wait for the Gitea API" sia
"Report Gitea health" passati puliti nel run successivo.

## Bug 11 — L'utente admin di Gitea non viene mai creato

**Sintomo**: risolti i Bug 9-10, arriva al task
`gitea_config : Require an API token`, che fallisce:
`vault_gitea_api_token is empty`.

**Causa**: nel log di `bootstrap.sh` (che gira *prima* del playbook
Ansible): `[FAIL] could not create a Gitea token: Command error: user
does not exist [uid: 0, name: forgeadmin]`. `compose/.env.example`
documenta esplicitamente questo account come "created by
bootstrap/bootstrap.sh (`gitea admin user create`)" — ma quella
chiamata **non esiste da nessuna parte** nello script (verificato con
`grep`). `GITEA__security__INSTALL_LOCK: "true"` disabilita il wizard
di setup di Gitea, quindi senza quella chiamata l'utente admin non
viene mai creato da nient'altro. Stesso schema del Bug 2
(`libvirt_host` mai collegato): comportamento documentato, mai
implementato.

**Verifica sintassi prima di scrivere il comando**: `docker exec -u git
forge-gitea gitea admin user create --help`, contro il binario reale
in esecuzione, non a memoria.

**Correzione**: aggiunta la chiamata mancante in `create_gitea_token()`
di `bootstrap.sh`, usando `GITEA_ADMIN_PASSWORD`/`GITEA_ADMIN_EMAIL`
già scritti in `compose/.env` da `create-secrets.sh` ma mai consumati
da nessuno — verificato con `grep -c` sul `.env` reale della VM che
tutte e tre le variabili esistessero davvero prima di scrivere il fix.
Idempotente, stessa tolleranza "already exists" già usata dal passo di
creazione del token subito dopo.

**Commit**: `e9cbf5b`.

**Stato**: risolto, da confermare nel prossimo run.
