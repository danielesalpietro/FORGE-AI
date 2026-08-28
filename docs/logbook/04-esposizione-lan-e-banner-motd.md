# 04 — Esposizione delle WebGUI sulla LAN e banner di login

## Contesto

Su richiesta di Daniele: esporre solo le WebGUI di management (Gitea,
Semaphore) sulla LAN, senza tunnel SSH, senza toccare nient'altro
(DHCP/dnsmasq, git-over-SSH, boot server) — e aggiungere un banner di
login che mostri i servizi attivi.

## Verifica di sicurezza prima di procedere

Confermato con `curl` diretto contro l'host reale (non assunto) che il
DHCP di FORGE-AI (dnsmasq) è legato esclusivamente al bridge
`virbr-forge` (`interface=`, `listen-address=192.168.250.1`,
`bind-dynamic`, `except-interface=lo` — letto da
`ansible/templates/dnsmasq/provisioning.conf.j2`, che dichiara
esplicitamente nel commento: "must never answer DHCP on a production
LAN"). Esporre il proxy nginx sulla LAN non ha alcuna relazione con
questo — sottosistemi Docker/rete completamente separati.

## Bug trovato prima di implementare: `BIND_ADDRESS` condivisa

`compose/docker-compose.yml` usava la stessa variabile `BIND_ADDRESS`
sia per la porta SSH di Gitea (2222, git push/pull) sia per le porte
del proxy TLS (8081/8443, le WebGUI) — cambiarla avrebbe esposto anche
git-over-SSH, non richiesto. Introdotta `PROXY_BIND_ADDRESS` dedicata
solo al proxy, default `127.0.0.1` invariato; `BIND_ADDRESS` resta solo
per la porta SSH.

**Commit**: `efbee19`.

## Regressione auto-inflitta e correzione

Impostato `PROXY_BIND_ADDRESS=192.168.1.171` in `compose/.env` e
rilanciato `bootstrap.sh`: **Stage 6/7 rotto di nuovo** —
`[FAIL] Gitea did not become ready within 180s`. Causa: `stage_gitops`
e `create_semaphore_token()` in `bootstrap.sh` avevano `--resolve
...:127.0.0.1` **fisso** per raggiungere il proxy — corretto in
precedenza (783ef42) quando il proxy era ancora solo su loopback, mai
aggiornato per seguire `PROXY_BIND_ADDRESS`. Corretto leggendo il
valore reale da `compose/.env` con fallback a `127.0.0.1`.

**Commit**: `7a1fd69`.

**Verifica dopo la correzione**: `bootstrap.sh` di nuovo `EXIT_CODE=0`,
e verificato **dalla macchina Windows** (non dalla VM stessa):

    curl -sk --resolve gitea.poc.local:8443:192.168.1.171 https://gitea.poc.local:8443/api/healthz     -> 200
    curl -sk --resolve semaphore.poc.local:8443:192.168.1.171 https://semaphore.poc.local:8443/api/ping -> 200

Entrambe le WebGUI raggiungibili dalla LAN reale, senza tunnel SSH.

## Banner di login (MOTD)

Aggiunto `ansible/templates/motd/50-forge-ai.j2`, reso come
`/etc/update-motd.d/50-forge-ai` da un nuovo task in
`bootstrap-control-plane.yml`. Mostra Gitea/Semaphore/boot
server/state API, e **adatta il testo** in base al valore reale di
`PROXY_BIND_ADDRESS` letto da `compose/.env` al momento del render
(istruzioni di tunnel SSH se loopback, istruzioni "aggiungi al file
hosts" con l'IP reale se pubblicato sulla LAN).

**Verificato eseguendo lo script direttamente** (non assunto dal solo
render):

    FORGE-AI control plane

      Gitea       https://gitea.poc.local:8443
      Semaphore   https://semaphore.poc.local:8443
      Boot server http://192.168.250.1:8080
      State API   http://192.168.250.1:8080/api/state

    Published on the LAN. Add to your hosts file:
      192.168.1.171  gitea.poc.local semaphore.poc.local

**Commit**: `2e1119b`.

## Nota tecnica: conversione automatica dei path (MSYS2)

Riscontrato di nuovo il fenomeno già documentato nella voce 01: un
comando `plink` con un argomento che sembra un path POSIX assoluto
(`/etc/update-motd.d/...`) viene riscritto da Git Bash su Windows prima
di raggiungere l'eseguibile nativo. Risolto con lo stesso prefisso
`MSYS_NO_PATHCONV=1` già in uso.

## Stato

Fatto. Le due WebGUI sono ora raggiungibili dalla LAN, `PROXY_BIND_ADDRESS`
resta un'opzione (default loopback) per chi preferisce il tunnel SSH,
e il banner di login riflette sempre la configurazione reale.
