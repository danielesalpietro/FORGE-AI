# Project review — consolidamento e sblocco del provisioning Windows

Stato di partenza: campagna di validazione 2026-08-28 → 2026-08-30 su
hardware reale, consolidata in
[`docs/logbook/logbook_finale.md`](logbook/logbook_finale.md).
Percorso Linux completo e verificato end-to-end; percorso Windows
funzionante fino all'ultimo anello (bug 32 aperto su `setup.exe`);
31 bug reali corretti sul branch
`claude/gitops-infrastructure-poc-9losz4`.

Questo documento è il piano operativo approvato per: mettere al sicuro
il lavoro fatto (0.1), stabilire se il bug 32 dipende dall'ambiente o
dal metodo (0.2), risolverlo per gradi di costo crescente (0.3), e
completare la pipeline mai eseguita (1).

---

## Pista principale per il bug 32 (dalla ricerca esterna)

`setup.exe` lanciato da dentro WinPE scrive i propri file di lavoro
(`$WINDOWS.~BT\Sources\...`, inclusi i log Panther che non abbiamo mai
trovato) su un **volume NTFS locale scrivibile** — non sulla RAM disk
X:. Caso documentato di Server 2025 che fallisce così da WinPE:
access denied creando `$WINDOWS.~BT` su un percorso non scrivibile
([Microsoft Community Hub](https://techcommunity.microsoft.com/discussions/windows-deployment/installing-windows-server-2025-is-failing-with-this-error-/4495633)).

Nel nostro ambiente, dopo il fix del bug 31, `diskpart` esegue
`clean` + `convert gpt` **senza creare né formattare alcun volume**:
al lancio di Setup non esiste alcuna destinazione scrivibile (la share
SMB è read-only per scelta di sicurezza). La timeline collima:

- il bug 32 è comparso **solo dopo** il bug 31;
- l'unico run che raggiunse la fase di staging (`NewOs`) avvenne
  quando il disco portava ancora partizioni formattate da un tentativo
  precedente;
- il fallimento senza alcun log scritto è coerente: fallisce la
  creazione del posto dove i log andrebbero scritti.

Test di verifica: `create partition primary` + `format fs=ntfs quick`
nello script diskpart. Costo: minuti.

---

## Fase 0.1 — Consolidamento (~½ giornata)

Obiettivo: il valore acquisito va messo al sicuro ora, non tenuto in
ostaggio dal bug 32.

- [ ] Aprire la PR dal branch `claude/gitops-infrastructure-poc-9losz4`
      verso `develop` (31 fix verificati + migrazione CD-ROM
      dell'answer file + logbook completi).
- [ ] Aggiornare Issue #2 con lo stato reale (Ubuntu completo, Windows
      all'ultimo anello, bug 32 aperto con pista).
- [ ] Snapshot ESXi di `forge-poc-host-2` come checkpoint post-bug-31
      (l'ultimo risale a bug 15-23).
- [ ] Rendering test per `motd/50-forge-ai.j2` (unico gap di copertura
      segnalato dalla suite; oggi fa anche fallire
      `make validate`/`validate-templates`).
- [ ] Valutare sudo NOPASSWD per l'utente di automazione sull'outer
      host (oggi ogni run non interattivo richiede `--ask-become-pass`
      con password su stdin — attrito documentato più volte nel
      logbook).

## Fase 0.2 — Test dell'unattended fuori dall'ambiente attuale (~1 giornata)

Obiettivo: stabilire se il bug 32 dipende dall'ambiente (KVM annidato
dentro ESXi, share Samba, WinPE via wimboot) o dal metodo in sé. Tre
prove in ordine di isolamento crescente, direttamente su ESXi (lo
stesso hypervisor dove gira l'outer VM):

1. **VM ESXi + ISO ufficiale Server 2025 + `autounattend.iso` come
   secondo CD-ROM** — lo stesso file che il ruolo `windows_unattend`
   già genera. È il percorso canonico per cui Setup è progettato e
   testato. Se funziona: prova che answer file e configurazione sono
   corretti, problema confinato al *come* lanciamo Setup in WinPE.
2. **VM ESXi + boot WinPE + setup.exe dalla share SMB** — replica del
   nostro flusso su hypervisor diverso: isola il fattore
   KVM-annidato.
3. Matrice di lettura: 1 ok / 2 no → il problema è il metodo
   WinPE+share; 1 ok / 2 ok → è l'ambiente KVM annidato; entrambe no
   → answer file/media (improbabile, già escluso con evidenza).

Strumenti già disponibili e collaudati dalla campagna: `govc`,
`vim-cmd`, upload datastore via HTTPS, screenshot console.

## Fase 0.3 — Risoluzione bug 32, per costo crescente (~½–2 giornate)

1. **Volume NTFS nello script diskpart** (pista principale, sopra) —
   da fare per primo, costo minuti. Nota: l'answer file
   `DiskConfiguration` con `WillWipeDisk=true` rimpiazza comunque il
   layout, quindi il volume pre-creato serve solo da scratch per
   Setup e non confligge.
2. Se non basta: **`dism /apply-image` + `bcdboot`** al posto di
   `setup.exe` — il metodo dei deployment enterprise (MDT/SCCM),
   bypassa per intero il componente che fallisce. Caveat verificati:
   DISM non processa i pass `windowsPE` (già coperti dal nostro
   diskpart) e l'unattend per `specialize`/`oobeSystem` va copiato in
   `C:\Windows\Panther\unattend.xml` dopo l'apply. Redesign contenuto
   del passo 6 di `startnet.cmd.j2`.
3. Medio termine (non per il bug): **Cloudbase-Init + metadata
   drive** per avvicinare il post-install Windows al modello
   cloud-init già usato per Ubuntu — solo dopo che il percorso base
   funziona.

## Fase 1 — Completamento pipeline (dopo lo sblocco)

Mai eseguite su hardware reale; per Linux sono sbloccate fin d'ora e
possono partire in parallelo alla 0.3:

- [ ] `make configure`
- [ ] `make validate-deployment`
- [ ] `make smoke-test`
- [ ] Prova di idempotenza (`make configure` ×2, atteso `changed=0`)
- [ ] Drift: `make drift`, `drift-report`, `reconcile`, `report`
- [ ] `make test-integration`, `make test-molecule`

---

## Nota sul modello di esecuzione

L'intera campagna (bug 24-32, diagnosi su console reale comprese) è
stata eseguita con un modello di classe Sonnet: per il lavoro
diagnostico su hardware (0.2, 0.3) quella classe è dimostrata
sufficiente e resta la raccomandazione; un modello di classe superiore
non è necessario. Le attività meccaniche della 0.1 e della fase 1
(PR, aggiornamento issue, esecuzione di target make già scritti)
sarebbero alla portata anche di un modello inferiore, ma il risparmio
non giustifica lo split di contesto: la regola operativa che ha retto
la campagna (mai agire su assunzioni non verificate,
`CLAUDE.md`) pesa più della capacità grezza.
