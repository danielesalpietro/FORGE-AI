# Logbook finale — consolidamento della validazione end-to-end di FORGE-AI

Documento di sintesi che consolida i logbook 00-06. Copre l'intera
campagna di validazione su hardware reale (host ESXi `192.168.1.133`,
2026-08-28 → 2026-08-30): cosa funziona, cosa è stato corretto, cosa
resta aperto, e le lezioni di metodo emerse. Il dettaglio di ogni
diagnosi, con l'evidenza raccolta, resta nei logbook numerati; questo
documento è la mappa, non il territorio.

---

## 1. Quadro complessivo

| Fase | Esito | Logbook |
|---|---|---|
| Accesso e ricognizione ESXi | Completata | 00 |
| Preparazione autoinstall Ubuntu (outer host) | Completata | 01 |
| Creazione VM outer + autoinstall end-to-end | **Completata e verificata** | 02 |
| Fase 5 — bootstrap control plane (`bootstrap.sh`) | **EXIT_CODE=0, 13 bug corretti** | 03 |
| Esposizione WebGUI su LAN + MOTD | Completata (bug 14) | 04 |
| Fase 6 — `make provision-ubuntu` (`poc-ubuntu-01`) | **Primo host FORGE-AI mai installato end-to-end, bug 15-23** | 05 |
| Fase 6 — `make provision-windows` (`poc-windows-01`) | **Parziale: catena di boot al 100%, Setup bloccato (bug 32 aperto)** | 06 |
| `make configure`, `validate-deployment`, `smoke-test`, idempotenza, drift | Mai eseguite | — |

**Trentuno bug reali di repository trovati e corretti** (1-31), ognuno
con diagnosi su evidenza diretta, fix, lint/test, commit e push. Un
bug aperto (32). Tutti i fix vivono sul branch
`claude/gitops-infrastructure-poc-9losz4`.

## 2. Cosa è dimostrato funzionante su hardware reale

**Percorso Linux — completo.** Da commit a macchina accesa e
raggiungibile: PXE → iPXE → kernel/initrd Ubuntu → autoinstall
Subiquity → callback di stato → riavvio su disco locale → SSH
funzionante. `make provision-ubuntu` termina con `EXIT_CODE=0`,
`failed=0`, senza alcun intervento manuale. Checkpoint: snapshot ESXi
`poc-ubuntu-01-installed-bug15-23`.

**Percorso Windows — funzionante fino all'ultimo anello.** Tutta la
catena che FORGE-AI controlla direttamente è verificata:

1. PXE/iPXE dispatch per MAC con guardia anti-reinstallazione;
2. wimboot scarica bootmgr/BCD/boot.sdi/boot.wim e inietta lo
   `startnet.cmd` per-host;
3. il WIM avvia l'immagine WinPE corretta (indice 1, boot index
   impostato — bug 28) ed esegue startnet.cmd;
4. `drvload` carica i 5 driver VirtIO ("Successfully loaded" per
   viostor, vioscsi, netkvm, balloon, vioser);
5. `wpeinit` + DHCP: IP corretto dalla reservation;
6. `net use` monta la share SMB `winmedia` (dopo il fix permessi,
   bug 29);
7. `diskpart` porta online, sblocca, pulisce e converte in GPT il
   disco (bug 31);
8. l'answer file arriva su un CD-ROM virtuale dedicato, costruito da
   Ansible e smontato/eliminato a installazione conclusa
   (riprogettazione post-bug 28/30).

L'unico anello che fallisce è l'invocazione di `setup.exe` di
Windows Server 2025 da dentro WinPE (bug 32, sotto).

## 3. Indice dei bug per sottosistema

| # | Sottosistema | Sintesi | Logbook |
|---|---|---|---|
| 1-13 | bootstrap.sh / Ansible control plane | path template, ruolo mai chiamato, pool libvirt, jmespath, timeout DHCP, porte Gitea/Semaphore, admin Gitea mai creato, `is changed` su `uri` | 03 |
| 14 | template MOTD | `regex_replace` backreference doppio backslash | 04 |
| 15-18 | forge-dnsmasq | CAP_SETPCAP, leasefile, seccomp vs capset(), UID drop vs TFTP secure | 05 |
| 19-20 | iPXE scripting | divisore `---` letto come opzione; `params` non supportato dal build | 05 |
| 21 | risorse VM | 4 GB insufficienti per fetch ISO in tmpfs casper → 8 GB | 05 |
| 22 | boot locale UEFI | `sanboot --drive 0x80` è BIOS-only → `exit` (3 punti) | 05 |
| 23 | autoinstall Ubuntu | sudo NOPASSWD mancante per l'utente di automazione | 05 |
| 24 | wimlib/Ansible | output UTF-16 di `--xml` rompe il protocollo JSON di Ansible → iconv | 06 |
| 25 | verifica driver | regex con backslash vs output forward-slash di `wimlib-imagex dir` | 06 |
| 27 | video model | `qxl` non supportato dal QEMU dell'host → `bochs` | 06 |
| 28 | boot.wim | driver iniettati nell'immagine "Setup" che bypassa startnet.cmd → indice 1 + boot index | 06 |
| 29 | Samba/permessi | `7z x` estrae tutto 644; `force user = nobody` nega l'esecuzione di setup.exe → chmod post-extract | 06 |
| 30 | answer file | conflitto rilevamento-automatico/flag-esplicito su `\Windows\System32\Autounattend.xml`; poi `--name` di wimboot | 06 |
| 31 | diskpart | disco offline/readonly da tentativo precedente → `online disk` + `attributes clear readonly` | 06 |
| 32 | **setup.exe (APERTO)** | esce `0xC190011F` prima di scrivere log; rilanci a esito non deterministico | 06 |

(Il numero 26 non è stato assegnato: la numerazione è saltata da 25 a
27 nel logbook 06 ed è stata mantenuta per coerenza con i commit.)

## 4. Bug 32 — stato preciso di ciò che si sa

**Sintomo**: il primo `I:\setup.exe` (build 26100.32230, eseguito
dalla share SMB in WinPE) lanciato da `startnet.cmd` esce quasi
immediatamente con errorlevel -1047527137 (`0xC190011F`), senza mai
creare `setupact.log`/`setuperr.log` (in `X:\Windows\Panther\` restano
solo file di telemetria).

**Escluso con evidenza diretta**:
- l'answer file e il suo meccanismo di consegna (fallisce identico
  senza alcun answer file, e con la consegna via CD-ROM);
- i permessi di esecuzione (bug 29 risolto, niente più "Access is
  denied");
- i driver storage (diskpart vede e prepara il disco ogni volta);
- lo schema XML (lo stesso file completo, letto da `I:\`, ha portato
  Setup fino alla fase di staging `NewOs` in un tentativo riuscito).

**Osservato ma non spiegato**: i rilanci manuali da console
interattiva a volte aprono la GUI di Setup (`errorlevel 0`), a volte
restituiscono 0 senza GUI; il retry-loop batch in `startnet.cmd` (3
tentativi, provato con pause di 5 s e di 60 s) fallisce invece sempre.
Qualcosa distingue il contesto del lancio batch da quello interattivo,
non ancora identificato. Il retry-loop resta nello script come
mitigazione innocua ma inaffidabile.

**Alternativa più promettente non ancora tentata**: sostituire
`setup.exe` con `dism /apply-image` + `bcdboot` (il metodo
MDT/SCCM) — bypassa per intero il componente che fallisce. Vedi il
Project review per il piano.

## 5. Limiti operativi noti (non bug del repository)

- **Flakiness SMB `winmedia`**: sotto decine di reset ravvicinati
  della stessa VM la share smette di rispondere al guest (error 53)
  pur restando raggiungibile dall'host; un riavvio del container la
  ripristina. Non riproducibile nel flusso operativo normale.
- **sudo non-interattivo**: `dsalpietro` sull'outer host non ha
  NOPASSWD; ogni playbook lanciato da una sessione non interattiva
  richiede `--ask-become-pass` con la password su stdin.
- **`make validate` parziale**: `validate-templates` fallisce su
  `motd/50-forge-ai.j2` (fact `ansible_default_ipv4` non disponibile
  nel rendering statico) — preesistente, non correlato a Windows.
- **Copertura test**: `motd/50-forge-ai.j2` è l'unico template senza
  rendering test (gap preesistente segnalato dalla suite).

## 6. Lezioni di metodo (pagate sul campo)

1. **Mai fidarsi di un "completed" senza l'exit code reale.** Più
   volte il wrapper di background ha riportato successo con
   `EXIT_CODE=2` nel log. La regola in MEMORY.md esiste per questo.
2. **"Bloccato" va dimostrato, non dedotto**: `/proc/<pid>/io`,
   CPU time crescente, `ss -tpi`. Diversi presunti stalli erano I/O
   lento genuino (checksum di file da 8-85 GB sotto contesa); un paio
   erano stalli veri (sudo senza password, download TCP morto).
3. **I processi orfani sopravvivono ai timeout locali**: un timeout
   del client non uccide l'albero remoto. Sempre
   `run_in_background`, mai timeout brevi su comandi remoti lunghi;
   `pkill` non trova i figli `AnsiballZ_*` (cmdline diversa).
4. **XML: quattro occorrenze dello stesso errore autoinflitto** (`--`
   letterale nei commenti di `domain.xml.j2`). I rendering test lo
   catturano; scriverli prima paga.
5. **Isolare per eliminazione batte decodificare i codici errore**:
   per i bug 30 e 32 il progresso è arrivato da test A/B con lo
   stesso file byte-per-byte in percorsi diversi, non dalla ricerca
   del significato di `0xC190011F` (tuttora non documentato da
   Microsoft nelle pagine consultate).
6. **Quando un sottosistema accumula bug indipendenti nello stesso
   punto** (28, 30 e in parte 32, tutti attorno alla consegna
   wimboot/setup.exe), il problema è di design, non di
   implementazione: la modalità "non convenzionale" di usare Windows
   Setup fuori dai canali per cui è testato produce fragilità a
   catena. La migrazione a CD-ROM è nata da questa osservazione.
7. **Il segreto non viaggia**: la password admin (codificata,
   reversibile) è passata da "servita via HTTP e iniettata nel WIM" a
   "solo su un CD-ROM locale, staccato ed eliminato a fine
   installazione" — un miglioramento di postura ottenuto come effetto
   collaterale del debug.

## 7. Cosa resta da fare (oltre il bug 32)

Dal tracker di Issue #2, mai eseguiti su hardware reale:
`make configure`, `make validate-deployment`, `make smoke-test`,
prova di idempotenza (`make configure` ×2, atteso `changed=0`),
drift detection/reconciliation (`make drift`, `drift-report`,
`reconcile`, `report`), `make test-integration`, `make test-molecule`.
Per il percorso Linux sono tutti sbloccati fin d'ora; per Windows
restano dietro al bug 32.
