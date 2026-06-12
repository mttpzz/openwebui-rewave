# Guida utente — ReWave AI

Guida completa all'assistente chat aziendale **ReWave AI** di Rewave Srl. Ogni
funzione è spiegata con esempi pratici.

ReWave AI è un assistente che conosce il mondo della cartotecnica e i documenti
aziendali, risponde in **italiano**, e può leggere i tuoi documenti, cercare sul
web e analizzare immagini.

**Indice**

1. [Per iniziare](#1-per-iniziare)
2. [Comandi rapidi (/)](#2-comandi-rapidi-)
3. [Cosa sa l'assistente — la conoscenza aziendale](#3-cosa-sa-lassistente--la-conoscenza-aziendale)
4. [Ricerca sul web](#4-ricerca-sul-web)
5. [Documenti in chat (al volo)](#5-documenti-in-chat-al-volo)
6. [Conoscenza / Knowledge Base (collezioni)](#6-conoscenza--knowledge-base-collezioni)
7. [Immagini (analisi visiva)](#7-immagini-analisi-visiva)
8. [Calcoli e date](#8-calcoli-e-date)
9. [Citazioni e fonti](#9-citazioni-e-fonti)
10. [Consigli per risposte migliori](#10-consigli-per-risposte-migliori)

---

## 1. Per iniziare

**Accesso**
1. Apri il browser su **`https://oi.rewave.local`**.
2. Clicca **Keycloak SSO** e accedi con le tue credenziali aziendali (lo stesso
   login degli altri servizi). Non c'è una password separata per la chat.

**La schermata**
- **Nuova chat**: pulsante in alto a sinistra. Il modello è **ReWave AI** (è l'unico,
  già selezionato).
- **Scrivi** la domanda in basso e premi Invio.
- **Cronologia**: le chat passate restano nella barra a sinistra. Puoi
  **rinominarle**, raggrupparle in **cartelle**, o eliminarle.
- Su ogni risposta puoi **Copiare** il testo, **Rigenerare** la risposta, o
  fermarla mentre scrive.

**Suggerimento:** apri una **chat nuova** per ogni argomento diverso. Conversazioni
pulite = risposte migliori.

---

## 2. Comandi rapidi (/)

Per i compiti ripetitivi ci sono **comandi pronti**: scrivi `/` nel campo del
messaggio e scegli dal menu. Il comando inserisce un testo già impostato, che poi
completi con il tuo caso specifico.

**Comandi disponibili:**

| Comando | Cosa fa |
|---|---|
| `/riassumi` | Riassume un documento o testo in punti chiave |
| `/estrai-fattura` | Estrae i dati di una fattura in tabella |
| `/traduci-en` | Traduce un testo in inglese |
| `/normativa` | Spiega in pratica una normativa per la cartotecnica |
| `/scheda-tecnica` | Genera una scheda tecnica di un prodotto cartotecnico |
| `/punti-azione` | Estrae i punti d'azione (attività, responsabile, scadenza) |

**Come si usa:**
1. In chat scrivi **`/`** (compare il menu dei comandi).
2. Scegli il comando (o continua a digitarne il nome).
3. Completa la richiesta: per `/normativa`, `/traduci-en`, `/scheda-tecnica`
   scrivi l'argomento dopo il comando; per `/riassumi`, `/estrai-fattura`,
   `/punti-azione` di solito **alleghi prima il documento** (vedi sezione 5) o
   incolli il testo.
4. Invio.

> *Esempio:* allega una fattura → scrivi `/estrai-fattura` → Invio.

---

## 3. Cosa sa l'assistente — la conoscenza aziendale

ReWave AI ha sempre in memoria una **base di conoscenza sulla cartotecnica**
(materiali, lavorazioni, normative di settore, fornitori, enti). Non devi caricare
nulla: puoi chiedere direttamente.

**Esempi:**
- "Spiegami la differenza tra cartone ondulato e cartoncino teso."
- "Quali sono le fasi della fustellatura?"
- "Cosa prevede la normativa MOCA per gli imballaggi a contatto con alimenti?"
- "Cos'è la nobilitazione e quali tecniche esistono?"

Risponde in italiano e, quando l'informazione arriva dalla conoscenza aziendale,
**indica le fonti** (vedi [sezione 9](#9-citazioni-e-fonti)).

---

## 4. Ricerca sul web

Quando l'informazione non è nella conoscenza aziendale, ReWave AI può **cercare sul
web** e leggerne i risultati.

**Come si usa:**
- Vicino al campo del messaggio c'è l'interruttore **Ricerca web** (icona mappamondo).
  Di norma è già attivo. Quando è attivo, l'assistente cerca online se serve.
- Fai la domanda normalmente.

**Esempi:**
- "Cerca le ultime novità sul mercato del packaging sostenibile in Italia."
- "Trova le scadenze fiscali aggiornate per le PMI quest'anno."

Le risposte dal web riportano i **link alle fonti**: controllale per i dati che
contano.

---

## 5. Documenti in chat (al volo)

Per fare domande su **un documento specifico**, senza salvarlo.

**Formati supportati:** PDF, Word (`.docx`), Excel (`.xlsx`), PowerPoint (`.pptx`),
testo (`.txt`), CSV (`.csv`), Markdown (`.md`).

**Come si fa:**
1. Apri una chat.
2. Trascina il file nella chat (oppure clicca l'icona **➕ / graffetta** e selezionalo).
3. Aspetta l'anteprima del file (l'assistente lo sta leggendo).
4. Scrivi la tua domanda (anche con un comando rapido, es. `/riassumi`).

**Esempi pratici:**

| Esempio d'uso | Cosa carichi | Cosa chiedi |
|---|---|---|
| Contabilità | Una fattura | "Estrai fornitore, n° fattura, data, imponibile, IVA, totale, scadenza" |
| Amministrazione | Un contratto | "Riassumi i punti chiave" · "Cosa dice la clausola sui pagamenti?" |
| Amministrazione | Una circolare/normativa | "Cosa comporta in pratica per la nostra azienda?" |
| Progettazione | Scheda tecnica di un cliente | "Quali dimensioni e grammatura richiede?" · "Che finiture servono?" |

**Note:**
- Il documento vive **solo in quella chat**. In una chat nuova devi ricaricarlo.
- Limiti: max **50 MB** per file, fino a **10 file** per chat.
- Le **scansioni** vanno caricate come **PDF**: vengono lette con OCR (riconoscimento
  testo, italiano + inglese). Più la scansione è pulita e dritta, migliore è il
  risultato.

---

## 6. Conoscenza / Knowledge Base (collezioni)

Per documenti che servono **spesso** e a **più persone**: invece di ricaricarli ogni
volta, li metti una volta in una **collezione** (sezione **Conoscenza** di Open
WebUI) e l'assistente li consulta quando serve.

> **Conoscenza aziendale vs Knowledge Base — la differenza**
> - La **conoscenza aziendale** (sezione 3) è curata centralmente ed è *sempre*
>   presente nelle risposte.
> - Una **Knowledge Base** è gestita dagli utenti e viene *consultata al bisogno*.
>   Usala per documenti troppi, specifici o che cambiano spesso.

### Creare una collezione

1. Apri **Workspace → Conoscenza** (Knowledge).
2. Clicca **+** (Crea collezione).
3. Dai un nome chiaro, es: `Normative fiscali`, `Capitolati clienti`,
   `Schede tecniche fustelle`.
4. **Trascina i documenti dentro** la collezione (stessi formati della sezione 5).
   L'assistente li legge e li indicizza.
5. Aggiungi/togli documenti quando vuoi: la collezione resta aggiornata.

### Usare una collezione in chat

- In chat scrivi **`#`** seguito dal nome della collezione (compare un menu da cui
  scegli), poi la domanda. L'assistente cerca la risposta lì dentro.
  > *Esempio:* `#normative-fiscali quali sono le scadenze IVA trimestrali?`
- Una collezione può anche essere **condivisa con tutta l'azienda** (chiedi
  all'amministratore): resta a richiesta con `#`, ma diventa visibile a tutti.

### Condividere una collezione

- Una collezione che crei è **privata finché non la condividi**. Per renderla
  disponibile ai colleghi, condividila con il **gruppo** appropriato (opzione di
  condivisione dentro la collezione).
- Non condividere documenti riservati che non vuoi rendere visibili al gruppo.
- Se il gruppo che ti serve non esiste ancora, chiedi all'amministratore di crearlo
  (oppure condividi con i singoli colleghi).

**Esempi pratici:**

| Collezione | Esempio di domanda |
|---|---|
| `Normative fiscali` | "Come gestiamo la fattura elettronica verso PA?" |
| `Capitolati clienti` | "Che tolleranze chiede il cliente X sulle scatole?" |
| `Schede tecniche fustelle` | "Quali fustelle abbiamo per scatole 200×150×80?" |

---

## 7. Immagini (analisi visiva)

Puoi **allegare un'immagine** (foto o screenshot) in chat e fare domande su ciò che
mostra.

**Esempi:**
- Foto di un prodotto/scatola → "Che tipo di lavorazione vedi su questa confezione?"
- Screenshot di una schermata o di un grafico → "Spiegami cosa rappresenta."

**Differenza con i documenti:** per **estrarre testo da un documento scansionato**
usa il **PDF** (sezione 5) — è più affidabile. L'analisi immagine serve per domande
**visive** (cosa si vede), non per archiviare/cercare testo.

---

## 8. Calcoli e date

L'assistente può fare **calcoli e operazioni con le date in modo affidabile**: usa
uno strumento dedicato invece di "stimare" a mente. Utile per contabilità,
preventivi e scadenze.

**Esempi:**
- "Calcola l'IVA al 22% su 1.481,00 € e il totale."
- "Quanti giorni mancano al 31/07?"
- "Fattura del 12/06, pagamento a 30 giorni fine mese: qual è la data di scadenza?"
- "Foglio 70×100, scatola 20×30: quante rese per foglio?"

Per importi e scadenze critici verifica comunque il risultato.

---

## 9. Citazioni e fonti

Quando la risposta si basa sulla conoscenza aziendale, sul web o su un documento che
hai caricato, ReWave AI mostra le **fonti** (riferimenti numerati `[1]`, `[2]` o
link). Cliccandole vedi da dove arriva l'informazione.

**Importante:** su dati fiscali, contrattuali o tecnici critici, **verifica sempre**
la fonte o il documento originale. L'assistente è un aiuto, non sostituisce il
controllo umano.

---

## 10. Consigli per risposte migliori

- **Sii specifico.** "Estrai imponibile e IVA dalla fattura" funziona meglio di
  "guarda questa fattura".
- **Un documento, una domanda chiara.** Se carichi 10 file e fai una domanda vaga,
  la risposta sarà vaga.
- **Verifica i numeri importanti.** Su dati fiscali/contrattuali critici controlla
  sempre l'originale.
- **PDF nativi (con testo) danno i risultati migliori.** Le scansioni e i
  PDF-immagine vengono letti con OCR: funziona bene su documenti puliti e dritti,
  meno bene su scansioni storte/sbiadite o su moduli con layout complesso (tante
  celle colorate, righe vuote, loghi). Se hai il PDF originale, preferiscilo.
- **Apri una chat nuova** per ogni nuovo argomento.
