# 06 — Fase 6: `make provision-windows` (poc-windows-01)

## Contesto

Dopo il successo completo di `poc-ubuntu-01` (bug 15-23, vedi
`docs/logbook/05-fase6-provisioning-target-vm.md`), primo tentativo di
provisioning di `poc-windows-01` (Windows Server 2025 Standard).

## Preparazione — trasferimento dell'ISO

L'utente ricordava di aver già scaricato l'ISO di Windows Server 2025
Evaluation sull'host ESXi. Verificato prima di assumere: `find
/vmfs/volumes -maxdepth 3 -iname '*win*'` conferma
`windows-server-2025-eval-en-us.iso` (8152356864 byte) sul datastore
`datastore1`, mai trasferita su `forge-poc-host-2` (solo l'ISO Ubuntu
era in `/srv/forge-ai/iso/`).

Trasferita con lo stesso metodo HTTPS già collaudato in questa sessione
per i trasferimenti di file grandi (scp/pscp si erano già dimostrati
inaffidabili su questa rete) — stavolta nel verso opposto: l'host
outer stesso ha fatto un `curl` diretto contro l'endpoint del
datastore ESXi:

    curl -sk -u "root:<password>" \
      'https://192.168.1.133/folder/ISOs/windows-server-2025-eval-en-us.iso?dcPath=ha-datacenter&dsName=datastore1' \
      -o /srv/forge-ai/iso/windows-server-2025-eval-en-us.iso

Verificato con `-I` (HEAD) prima di lanciare il download completo:
`content-length: 8152356864`, poi confermato a trasferimento concluso
che la dimensione finale corrispondeva esattamente.

`config/poc.yml` aggiornato (locale all'host, gitignored):
`media.windows.iso_path`, `iso_sha256` (calcolato da `make
windows-images`, pinnato per rilevare una ISO sostituita). `make
windows-images` ha confermato che `image_name: "Windows Server 2025
SERVERSTANDARD"` già presente nel file corrispondeva esattamente
all'edizione `[2]` reale dentro `install.wim` — nessuna correzione
necessaria lì.

`make lint` e `make validate-config` puliti prima di procedere.

## Bug 24 — `wimlib-imagex info --xml` stampa UTF-16, Ansible richiede UTF-8

**Sintomo**: `make provision-windows` fallisce al primo vero task
Windows-specifico:

    TASK [windows_media : Read the image metadata from the installation image]
    [ERROR]: Task failed: Refusing to deserialize an invalid UTF8 string value:
              'utf-8' codec can't encode characters in position 0-1: surrogates not allowed

**Diagnosi**: `ansible/roles/windows_media/tasks/inspect-wim.yml` esegue
`wimlib-imagex info {{ image }} --xml` con `ansible.builtin.command`,
poi ripulisce i byte nulli dall'output con `regex_replace('\x00', '')`
prima di estrarre gli indici con una regex — il codice era già
consapevole che l'output fosse "UTF-16 con BOM" (commento esistente),
ma il `regex_replace` non ha mai la possibilità di girare: il modulo
`command` di Ansible cattura lo stdout e lo fa transitare per il
proprio protocollo JSON interno tra il sottoprocesso del modulo e il
processo principale, che richiede UTF-8 valido. Byte UTF-16 decodificati
come UTF-8 producono "surrogati soli" (lone surrogates), non
rappresentabili in UTF-8 — la deserializzazione fallisce prima ancora
di restituire il risultato al playbook.

Verificato sull'host reale, non assunto:

    wimlib-imagex info install.wim --xml | file -
      -> /dev/stdin: Unicode text, UTF-16, little-endian text ...
    wimlib-imagex info install.wim --xml | head -c 60 | xxd
      -> 00000000: fffe 3c00 5700 4900 4d00 3e00 ...   (BOM FF FE, poi ogni carattere ASCII seguito da 0x00)

Controllato anche il percorso di fallback (`wimlib-imagex info` senza
`--xml`, usato solo se il parsing XML non trova nulla): quello **è**
già UTF-8 (`file -` conferma), non ha lo stesso bug — non toccato.

**Correzione applicata**: `ansible/roles/windows_media/tasks/inspect-wim.yml`
— il task cambiato da `ansible.builtin.command` a `ansible.builtin.shell`
(serve una pipe) con `wimlib-imagex info {{ image | quote }} --xml |
iconv -f UTF-16 -t UTF-8`, convertendo a UTF-8 valido **prima** che
Ansible catturi lo stdout. Il successivo `regex_replace('\x00', '')`
diventato superfluo (non ci sono più byte nulli intercalati dopo la
conversione) ed è stato rimosso.

**Verifica**: `wimlib-imagex info install.wim --xml | iconv -f UTF-16
-t UTF-8 | head -c 200` produce XML leggibile e valido
(`<WIM><TOTALBYTES>7255895157</TOTALBYTES><IMAGE INDEX="1">...`).
