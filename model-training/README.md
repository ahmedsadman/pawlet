# model-training

On-device SMS classification + field extraction models for the **pawlet** app.
Lives at `pawlet/model-training/` (Python training project inside the app repo).
Trains small BERT-family encoders (classification + NER), exports an fp32 ONNX
graph and converts it to a dynamic-range int8 TFLite model for Android.

## What this does

One dataset, two tasks:
- **Classification** — 5-way leaf label: `expense | income | transfer | bill | null`
  (covers pawlet's category + transaction type).
- **NER** — extract spans: `AMOUNT`, `BALANCE`, `DUE` (bill total), `PERIOD`
  (statement month/year). Currency is derived in-app from the token next to the
  amount (the dataset's `currency_span` has no char offsets).

Start with two stock models (simplest). Fusing them into one shared backbone
(smaller/faster on device) is a possible later optimization — but it may not be
worth it: each model is ~26 MB int8, and fusing only saves the one duplicated
backbone (~20–25 MB). Weigh that saving against the extra multi-task training +
re-evaluation it costs before deciding.

## Data

`data/sms-dataset-v1.jsonl` — 685 records: expense 186, bill 126, transfer 120,
null 118, income 135.

Every row is a real bank SMS format with the values substituted (amounts, card
numbers, client ids, merchants, dates). The layout is what the model learns, so
layout is reproduced exactly and only values change. The dataset is append-only
and hand-curated — nothing regenerates it.

Row fields: `message_id`, `sender`, `content`, `category`, the label fields for
that category, and char-offset spans. `sender` is metadata only — the model is
trained on `content` alone.

## Adding data

New rows arrive as a **committed one-shot script** that appends (see
`scripts/gen_city_amex.py` for the pattern). Never hand-edit the dataset: spans
are character offsets, and getting one wrong by a single character trains the
NER on a wrong answer that nothing will flag at training time.

1. Write a script that builds the rows and computes spans by construction.
   Use an unused `message_id` range (taken so far: `<10000`, `10001-10060`,
   `200001+`, `900000+`).
2. Dry-run it, eyeball the output, then `--apply` to append.
3. `python scripts/validate_dataset.py` — must print OK.
4. `python -m src.split && python -m src.train_classifier && python -m src.train_ner`
5. `python -m src.evaluate` — confirm metrics and read the per-record failures.

**Invariants** (enforced by `scripts/validate_dataset.py`): `content[start:end]`
equals `span.text`; the scalar field (`amount`/`balance`/`total_due`) equals
`span.text` with commas stripped; `message_id` and `content` are globally
unique; each category carries its required fields.

**One caveat on splitting.** Rows are assigned per row, so 20 variations of one
SMS format scatter across train/val/test. Test then measures extraction on
formats the model has already seen, which reads higher than performance on a
bank format it has never encountered. Keep that in mind when a new sender is
added and the metrics barely move.

## Setup

Local (Python 3.11/3.12):

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Or use Google Colab (free GPU) — upload `data/` + `src/`, `pip install -r requirements.txt`, run the same commands. Training is minutes on this dataset.

## Run

```bash
python scripts/validate_dataset.py  # check span/label invariants (run first)
python -m src.split              # build train/val/test  -> data/splits/
python -m src.train_fused        # seed-sweep -> models/fused  (THE shipped model)
python -m src.evaluate           # score a trained split (default test) -> report
python -m src.export_onnx        # -> models/fused_onnx/model.onnx (fp32 source graph)
python scripts/export_tflite.py  # onnx2tf + dynamic-range int8 -> app assets/model/model.tflite
```

`models/fused` is the artifact that matters: `evaluate`, `export_onnx` and the
app all read it. Retrain with `src.train_fused` or you will export and score a
stale model.

The two single-task trainers still exist and write `models/classifier` and
`models/ner`, but nothing downstream reads them — they are useful only for
isolating which head a regression lives in:

```bash
python -m src.train_classifier   # seed-sweep, keep best-by-val -> models/classifier
python -m src.train_ner          # -> models/ner, prints per-entity test report
```

`evaluate` runs the already-trained fused model over a split (no retraining) and
prints per-class + per-entity reports plus a per-record table (gold vs pred,
classifier confidence, NER weakest-span confidence). `python -m src.evaluate val`
for val. `python -m src.predict "..."` runs a single SMS.

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
(confidence, not correctness) and support (context).

## Config

`src/config.py`:
- `BACKBONE` — encoder (default `google/mobilebert-uncased`; alternatives listed).
- `VAL_FRAC` / `TEST_FRAC` — per-class split fractions (0.15 each; the rest is
  train). Rows are ordered by `sha1(SEED:content)`, so a row's split depends on
  its own text, not on the file's length or order — appending data moves only
  rows adjacent to a cut boundary instead of redealing everything. Change `SEED`
  to draw a different but equally reproducible split.
- `MAX_LEN`, `SEED`, label sets.

`train_classifier` sweeps seeds (env `SEEDS`, default `42,1,7,13,123`) and keeps
the run with the best validation macro-F1. `SEEDS=7` reproduces just the winner.

## Notes / gotchas

- **Train/serve parity.** The app must reproduce the exact tokenizer
  preprocessing used here, or accuracy drops. The app ships the HF WordPiece
  `tokenizer.json` and tokenizes in Dart (`dart_bert_tokenizer`); parity is
  guarded by `mobile-app/integration_test/local_model_parity_test.dart`.
- **605 is a v1.** Expect to keep adding SMS formats.
- **No per-row split overrides.** Every row goes through the hash. A row you
  want permanently evaluated cannot be forced into test; add more variations of
  that format instead, so some land in test on their own.

## License

Pawlet dataset & models © 2026 Ahmed Sadman Muhib

Licensed under [CC BY-SA 4.0](LICENSE). You may share and adapt this data and
these models, including commercially, provided you give appropriate credit and
release anything you adapt from them under the same license.
