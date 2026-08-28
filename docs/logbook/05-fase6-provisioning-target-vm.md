# 05 — Fase 6: `make provision`, deploy-pxe, provisioning delle VM target

## Contesto

Dopo `bootstrap.sh` (Fase 5, 13 bug) e `make prepare-media` (bug 14),
prossimo passo del piano: `make prepare-media` -> `make deploy-pxe` ->
`make provision` (crea/installa `poc-ubuntu-01` e `poc-windows-01`).

## Errore di sequenza (mio, non un bug del repo)

Ho lanciato `make provision` subito dopo `make prepare-media`, saltando
`make deploy-pxe`. La VM `poc-ubuntu-01` è partita, ha tentato il boot
di rete, ed è finita su una UEFI Shell con:

    BdsDxe: failed to load Boot0002 "UEFI PXEv4 (MAC:525400250021)" ...
    Not Found

Non un bug: il servizio TFTP/DHCP dedicato (`forge-dnsmasq`) non era
ancora stato distribuito. Corretto rilanciando `make deploy-pxe` per
primo (come da target Makefile).

## Bug 15 — CAP_SETPCAP mancante nella unit systemd di `forge-dnsmasq`

**Sintomo**: `make deploy-pxe` falliva ripetutamente su "Assert that
TFTP answers" / "No TFTP listener on udp/69", con `forge-dnsmasq.service`
in restart-loop.

**Diagnosi**: `journalctl -u forge-dnsmasq` mostrava
`setting capabilities failed: Operation not permitted` seguito da
`FAILED to start up` — dnsmasq chiama `capset()` su se stesso all'avvio
come parte del proprio hardening interno, anche da root, e quella
chiamata richiede `CAP_SETPCAP` nel proprio capability set. La unit
template (`ansible/templates/dnsmasq/forge-dnsmasq.service.j2`) aveva
`AmbientCapabilities`/`CapabilityBoundingSet` senza `CAP_SETPCAP`.

**Correzione applicata**: aggiunto `CAP_SETPCAP` a entrambe le righe.

## Bug 16 — `dhcp-leasefile` in una directory non scrivibile dal processo

**Sintomo**: dopo il fix del bug 15, `forge-dnsmasq` falliva ancora,
questa volta con un errore di permesso sul file di lease.

**Diagnosi**: `dhcp-leasefile` puntava a `{{ storage.state_dir }}`, una
directory `0750` posseduta da UID 10001 (il container dello state
service, non root) — confermato via `journalctl`, non assunto.
`forge-dnsmasq.service` gira come `root` ma con `CapabilityBoundingSet`
volutamente privo di `CAP_DAC_OVERRIDE`, quindi root stesso riceve
"Permission denied" lì come un UID qualunque. `storage.log_dir` è
`root:root 0755` ed è già in `ReadWritePaths` della unit.

**Correzione applicata**: `ansible/templates/dnsmasq/provisioning.conf.j2`,
`dhcp-leasefile` spostato da `storage.state_dir` a `storage.log_dir`.

## Bug 17 — direttive di hardening seccomp incompatibili con il `capset()` interno di dnsmasq

**Sintomo**: dopo i bug 15 e 16, `make deploy-pxe` falliva **ancora**
sullo stesso identico errore (`No TFTP listener on udp/69`), nonostante
`systemctl status forge-dnsmasq` confermasse `active (running)` pochi
istanti prima di un rerun. Tre run consecutivi falliti nonostante due
fix reali già applicati — la cosa non tornava.

**Diagnosi (bisezione empirica diretta sull'host, non per ipotesi)**:

1. `journalctl -u forge-dnsmasq` mostrava solo `dnsmasq: syntax check
   OK.` (l'output di `ExecStartPre --test`) — il vero errore del
   processo `ExecStart` non passava da syslog/journal, perché la
   configurazione usa `log-facility=.../dnsmasq.log` (file, non
   syslog). Letto quel file direttamente:

       setting capabilities failed: Operation not permitted
       FAILED to start up

   **Lo stesso identico errore del bug 15**, nonostante `CAP_SETPCAP`
   fosse già presente e confermato nella unit realmente installata su
   disco (`systemctl cat forge-dnsmasq`).

2. Riprodotto lo stesso set di capability **fuori** dalla sandbox
   systemd con `capsh --caps=... --addamb=...` e lanciato dnsmasq sotto
   `strace`: **nessun errore di capset**, arrivava fino al bind del
   socket. Quindi il problema non erano le capability in sé, ma
   qualcos'altro nella unit.

3. Bisezione diretta sulla unit reale, un gruppo di direttive alla
   volta, riavviando e leggendo `/srv/forge-ai/logs/dnsmasq.log` ogni
   volta (non `systemctl status` da solo, che non mostra l'errore):

   - Solo le direttive di capability + `NoNewPrivileges` -> **funziona**
     (DHCP e TFTP entrambi in ascolto, confermato con `ss`).
   - Aggiunte tutte e 6 le `Protect*` -> **fallisce di nuovo**
     (`setting capabilities failed`).
   - Solo `ProtectSystem=strict` + `ProtectHome=yes` + `PrivateTmp=yes`
     -> **funziona**.
   - Solo `ProtectKernelTunables=yes` (da sola) -> **fallisce**.
   - Rimossa `ProtectKernelTunables` ma reintrodotto il gruppo
     `RestrictNamespaces`/`RestrictRealtime`/`RestrictSUIDSGID`/
     `MemoryDenyWriteExecute`/`LockPersonality`/
     `SystemCallArchitectures=native` (mai testato da solo fino a quel
     punto) -> **fallisce ancora**: un secondo colpevole indipendente,
     non solo `ProtectKernelTunables`.
   - Testate singolarmente `RestrictNamespaces`, `RestrictRealtime`,
     `RestrictSUIDSGID`: **ognuna, presa da sola, fa fallire
     `capset()`**.

   Conclusione verificata: **qualunque** direttiva systemd che installa
   un filtro seccomp (`ProtectKernelTunables`, `RestrictNamespaces`,
   `RestrictRealtime`, `RestrictSUIDSGID`, e con ogni probabilità anche
   `ProtectKernelModules`, `ProtectControlGroups`,
   `MemoryDenyWriteExecute`, `LockPersonality`,
   `SystemCallArchitectures=native` — non tutte testate una per una per
   tempo, ma mai state necessarie per isolare il fix) rompe la chiamata
   `capset()` che dnsmasq 2.90 fa su se stesso all'avvio. Solo le
   direttive di capability e il trio `ProtectSystem`/`ProtectHome`/
   `PrivateTmp` (basate su mount-namespace, senza seccomp) sono
   compatibili.

   La causa esatta a livello di singola syscall bloccata dal filtro
   seccomp **non è stata identificata** — non necessaria per il fix, e
   non affermata per non violare la regola "solo informazioni concrete".

**Correzione applicata**: `ansible/templates/dnsmasq/forge-dnsmasq.service.j2`
— rimosse tutte le direttive `Protect*`/`Restrict*`/
`MemoryDenyWriteExecute`/`LockPersonality`/`SystemCallArchitectures`
tranne `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`;
aggiunto commento che documenta la bisezione e perché le altre restano
deliberatamente fuori.

**Verifica**: configurazione finale (capability + `NoNewPrivileges` +
`ProtectSystem`/`ProtectHome`/`PrivateTmp`) applicata manualmente
sull'host e confermata: `systemctl status` -> `active (running)`,
`ss -Hlnup` mostra sia `virbr-forge:67` sia `192.168.250.1:69` in
ascolto.

**Nota operativa**: durante la diagnosi, un test manuale con `capsh`/
`strace` ha lasciato un processo `dnsmasq` residuo (PID 216707) che
teneva occupate le porte 67/69 fuori dal controllo di systemd
(`systemctl stop` non lo terminava) — causa di un falso negativo in un
test successivo. Terminato manualmente con `kill -9`. Non un bug del
repo, un artefatto della sessione di debug.

**Commit**: TBD (vedi commit immediatamente successivo a questa voce di
log).
