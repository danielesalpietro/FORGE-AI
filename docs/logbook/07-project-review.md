# 07 — Esecuzione del Project review (#5)

Piano: `docs/PROJECT-REVIEW.md`. Issue principale #5, sub-issue #6-#9.

## 2026-08-30 — Fase 0.1: consolidamento (#6)

- **Commit mancante recuperato**: le modifiche della migrazione
  CD-ROM (ipotesi 4) e del retry-loop erano state sincronizzate
  sull'outer host via pscp ma mai committate in git — trovate come
  9 file modificati nel working tree locale al momento di aprire la
  PR. Committate come `3a381c7` (già verificate lint/pytest durante
  la sessione precedente). Lezione: il doppio canale
  "pscp per testare subito + git per la storia" richiede un
  `git status` di controllo a fine giro, non solo a inizio.
- **PR**: esisteva già la draft #1 (dal 2026-08-27, pre-hardware).
  Aggiornata con l'esito della campagna e marcata ready for review;
  la motivazione del draft ("mai esercitato su hardware reale") non
  sussiste più.
- **Issue #2** aggiornata: sezione Fase 6 Windows (bug 24-31 risolti,
  bug 32 → #8), pipeline residua → #9, rimando a #5.
- **Snapshot ESXi**: `windows-chain-bug24-31-cdrom-delivery` (id 4)
  su `forge-poc-host-2`. VM id **8** verificato con
  `vim-cmd vmsvc/getallvms` prima di agire (il logbook 02 riportava
  vmid 7 per la creazione: lo stato reale vince sul documento).
  Snapshot senza memoria a VM accesa (crash-consistent, come i
  checkpoint precedenti).
- **Bug motd** (rendering senza fact): `ansible_default_ipv4.address
  | default(...)` non protegge quando è il dict stesso a essere
  indefinito — sotto StrictUndefined l'accesso all'attributo esplode
  prima che il default si applichi. Fix nel template (default sul
  dict prima dell'attributo) + aggiunto a `GLOBAL_TEMPLATES` nel
  rendering test. Esito: **205/205 pytest verdi e `make validate`
  passa per intero per la prima volta nella campagna** (commit
  `55a71e2`).
- **sudo NOPASSWD** per `dsalpietro` sull'outer host: valutazione
  favorevole (attrito `--ask-become-pass` documentato più volte;
  in un'occasione la password è comparsa in `ps aux` per un
  `echo | sudo -S` mal costruito; VM dedicata su segmento isolato).
  L'installazione del drop-in sudoers è una modifica di sicurezza
  che il classificatore dell'ambiente di automazione blocca
  correttamente: consegnata come comando pronto nel commento di
  chiusura di #6, da eseguire manualmente.

Stato: Fase 0.1 chiusa (4/5 automatizzati, 1 consegnato per azione
manuale). Prossima: Fase 0.3 punto 1 (volume NTFS nel diskpart, il
test da minuti che può chiudere il bug 32) e/o Fase 0.2 su decisione
dell'operatore.
