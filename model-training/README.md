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
(smaller/faster on device) is a later optimization.

## Data

`data/sms-dataset-v1.jsonl` — 750 records, 150 per leaf class.
- `_source: "real"|"manual"` — real bank SMS (used for val/test).
- `_source: "augmented"` — synthetic (used for train only).
- Provenance: `scripts/generate_dataset.py`.

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
python -m src.train_classifier   # -> models/classifier, prints per-class test report
python -m src.train_ner          # -> models/ner, prints per-entity test report
python -m src.export_onnx        # -> models/*_int8/ (ship these in the app)
```

## Config

`src/config.py`:
- `BACKBONE` — encoder (default `google/mobilebert-uncased`; alternatives listed).
- `REAL_IN_TRAIN_FRACTION` — divert some real rows into train (default `0.0`,
  keeps eval fully real).
- `MAX_LEN`, `SEED`, label sets.

## Notes / gotchas

- **Augmented → train only, real → val/test.** Honest evaluation. Real minority
  classes (bill, transfer) are small, so their val/test counts are small — that
  is the real signal we have; add more real SMS over time.
- **Train/serve parity.** The app must reproduce the exact tokenizer
  preprocessing used here, or accuracy drops. Simplest: run tokenization inside
  the ONNX graph via ONNX Runtime Extensions.
- **750 is a v1.** Expect to keep adding real data.
