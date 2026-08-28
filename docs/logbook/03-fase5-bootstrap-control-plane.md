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

**Stato**: risolto, in verifica nel run successivo (esito non ancora
noto al momento della stesura di questa voce).
