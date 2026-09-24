# model-training

On-device SMS classification + field extraction models for the **meowni** app.
Lives at `meowni/model-training/` (Python training project inside the app repo).
Trains small BERT-family encoders (classification + NER), exports int8 ONNX for
Android.

## What this does

One dataset, two tasks:
- **Classification** — 5-way leaf label: `expense | income | transfer | bill | null`
  (covers meowni's category + transaction type).
- **NER** — extract spans: `AMOUNT`, `BALANCE`, `DUE` (bill total), `PERIOD`
  (statement month/year). Currency is derived in-app from the token next to the
  amount (the dataset's `currency_span` has no char offsets).

Start with two stock models (simplest). Fusing them into one shared backbone
(smaller/faster on device) is a possible later optimization — but it may not be
worth it: each model is ~26 MB int8, and fusing only saves the one duplicated
backbone (~20–25 MB). Weigh that saving against the extra multi-task training +
re-evaluation it costs before deciding.

## Data

`data/sms-dataset-v1.jsonl` — 750 records, 150 per leaf class.
- `_source: "real"|"manual"` — real bank SMS (used for val/test).
- `_source: "augmented"` — synthetic (used for train only).
- Provenance: `scripts/generate_dataset.py`.

## Adding real data

Real data is the durable asset; augmented is disposable. On every
`python scripts/generate_dataset.py` run, `rebuild()`:

1. Keeps **all** real/manual rows (deduped by exact content; real wins ties).
2. **Discards and regenerates** all augmented rows from scratch. Never hand-edit
   augmented rows — they are overwritten next run.
3. Backfills augmented per class only up to `target` (default 150):
   `augmented = target - real_count`. So real is always prioritized, and as real
   grows the synthetic share shrinks automatically.

**Workflow to add real SMS:**

1. Append each new real record to `data/sms-dataset-v1.jsonl` with `_source:
   "real"`, the correct schema for its category, and **verified char-offset
   spans** — `content[start:end]` must equal `span.text`, and the scalar field
   (`amount`/`balance`/`total_due`) must equal `span.text` with commas stripped.
   `rebuild()` asserts all of this and aborts on any mismatch, so compute offsets
   with a small script rather than by hand. Give it a `message_id` outside the
   augmented range (`200001+`); real ids are small, pinned regression ids use
   `900000+`.
2. `python scripts/generate_dataset.py` — regenerates, keeping your new real rows.
3. `python -m src.split && python -m src.train_classifier && python -m src.train_ner`
4. `python -m src.evaluate` — confirm metrics and that pinned regression cases
   still pass.

**Cap policy (150):**

- Augmented never pushes a class past `target`.
- Real is never dropped, so a class *can* exceed `target` once it has more than
  `target` unique real rows (augmented for it drops to 0). That overshoot is the
  signal that the class is now real-backed.
- Only raise `target` above 150 once the existing 150 are mostly real and
  diverse — bumping it too early just manufactures more synthetic data. Note
  `target` is **global**: raising it inflates augmentation for every class,
  including ones with little real data (e.g. transfer).

## Setup

Local (Python 3.11/3.12):

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Or use Google Colab (free GPU) — upload `data/` + `src/`, `pip install -r requirements.txt`, run the same commands. Training is minutes on this dataset.

## Run

```bash
python -m src.split              # build train/val/test  -> data/splits/
python -m src.train_classifier   # seed-sweep, keep best-by-val -> models/classifier
python -m src.train_ner          # -> models/ner, prints per-entity test report
python -m src.evaluate           # score a trained split (default test) -> report
python -m src.export_onnx        # -> models/*_int8/ (ship these in the app)
```

`evaluate` runs the already-trained models over a split (no retraining) and prints
per-class + per-entity reports plus a per-record table (gold vs pred, classifier
confidence, NER weakest-span confidence). `python -m src.evaluate val` for val.
`python -m src.predict "..."` runs a single SMS.

## Reading the evaluation

Every number the reports emit, what it means, and which direction is "better".
"Higher" always assumes the same test split — never compare metrics across
different splits.

| Metric | Appears in | What it means | Better |
|--------|-----------|---------------|--------|
| **precision** | per-class + NER report | Of the items *predicted* as class/entity X, the fraction actually X. Punishes false positives (over-tagging). | higher |
| **recall** | per-class + NER report | Of the *actual* class/entity X items, the fraction the model found. Punishes misses. | higher |
| **f1-score** | per-class + NER report | Harmonic mean of precision & recall — the single balanced score per class/entity. | higher |
| **support** | per-class + NER report | How many gold examples of that class/entity exist in the split. Context, not quality — a tiny support (e.g. bill=3) means its F1 is noisy. | n/a |
| **accuracy** | classifier report | Fraction of *all* records with the correct class. Dominated by big classes. | higher |
| **macro avg** | both reports | Unweighted mean across classes/entities — every class counts equally, so minority classes matter. **Primary score for our imbalanced data.** | higher |
| **weighted avg** | both reports | Mean weighted by support — big classes dominate. Close to accuracy. | higher |
| **micro avg** | NER report | Pools every entity instance before averaging — one score over all spans, dominated by frequent entities (AMOUNT/BALANCE). | higher |
| **class exact** | per-record summary | % of records whose class is correct (same as accuracy, shown per-record). | higher |
| **NER exact** | per-record summary | % of records where the *whole* predicted entity set exactly equals gold (every field right, none missing, none extra). Strict — one bad span fails the record. | higher |
| **CONF** | per-record table | Classifier confidence = softmax prob of the predicted class. **Confidence, not correctness.** High CONF on a wrong row (see 198) = model is confidently wrong — worse than a low-CONF miss. | context |
| **NERc** | per-record table | NER weakest-span confidence = the lowest span confidence in that record, where each span's confidence is its weakest token's prob. Low NERc flags fragile/fragmented extractions. | higher, but read alongside NER PASS/FAIL |
| **CLS / NER (PASS/FAIL)** | per-record table | Per-record correctness flags for class and entity-set. Failures sort to the top. | want PASS |

Same test split when comparing models; higher is better for all except CONF
(confidence, not correctness) and support (context). `*` in the ID column marks
pinned regression rows — those must stay PASS.

## Config

`src/config.py`:
- `BACKBONE` — encoder (default `google/mobilebert-uncased`; alternatives listed).
- `EVAL_REAL_PER_CLASS` — real rows per class reserved for eval (val+test),
  split 50/50; the rest of real + all augmented go to train.
- `MAX_LEN`, `SEED`, label sets.

`train_classifier` sweeps seeds (env `SEEDS`, default `42,1,7,13,123`) and keeps
the run with the best validation macro-F1. `SEEDS=7` reproduces just the winner.

## Notes / gotchas

- **Augmented → train only, real → val/test.** Honest evaluation. Real minority
  classes (bill, transfer) are small, so their val/test counts are small — that
  is the real signal we have; add more real SMS over time.
- **Train/serve parity.** The app must reproduce the exact tokenizer
  preprocessing used here, or accuracy drops. Simplest: run tokenization inside
  the ONNX graph via ONNX Runtime Extensions.
- **750 is a v1.** Expect to keep adding real data.
- **Pinning regression cases.** A dataset row can carry `_split: "test"` (or
  `"val"`/`"train"`) to force it into that split, bypassing the reserve logic —
  use it to permanently evaluate real SMS a past model got wrong.
