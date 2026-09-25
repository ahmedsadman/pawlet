"""Multi-task model: one shared backbone, two heads (5-way class + token NER).

Built on `AutoModelForSequenceClassification` rather than bare `AutoModel` so the
classification path keeps the backbone's own pooler/head (MobileBERT's pooler is
nonstandard — reimplementing it from `last_hidden_state[:, 0]` would silently
diverge from the current separate classifier). The NER head is a plain per-token
linear on the encoder's last hidden state, exactly what
`AutoModelForTokenClassification` does.

Label kwargs are `class_labels` / `ner_labels` (never `labels`), because HF
Trainer treats `labels` specially and a two-head model has two label tensors.
`forward()` returns a fixed-field-order `FusedOutput` so Trainer's prediction
tuple is deterministic in `compute_metrics`.

Construction:
  FusedModel.new_pretrained(cfg)   # training: pretrained backbone + fresh heads
  FusedModel.from_pretrained(dir)  # reload a trained fused model (standard HF)
"""
from dataclasses import dataclass
from typing import Optional

import torch
import torch.nn as nn
import torch.nn.functional as F
from transformers import (
    AutoConfig,
    AutoModelForSequenceClassification,
    PretrainedConfig,
    PreTrainedModel,
)
from transformers.utils import ModelOutput


@dataclass
class FusedOutput(ModelOutput):
    # field order is load-bearing: Trainer packs non-loss fields into
    # EvalPrediction.predictions in this order (class first, then ner).
    loss: Optional[torch.FloatTensor] = None
    class_logits: torch.FloatTensor = None
    ner_logits: torch.FloatTensor = None


class FusedConfig(PretrainedConfig):
    model_type = "fused_sms"

    def __init__(
        self,
        backbone: str = None,
        num_class_labels: int = 5,
        num_ner_labels: int = 9,
        class_weight: float = 1.0,
        ner_weight: float = 1.0,
        class_id2label: dict = None,
        ner_id2label: dict = None,
        **kw,
    ):
        super().__init__(**kw)
        self.backbone = backbone
        self.num_class_labels = num_class_labels
        self.num_ner_labels = num_ner_labels
        self.class_weight = class_weight
        self.ner_weight = ner_weight
        # both maps persisted (a single config.json id2label holds only one).
        # keys are stringified on JSON round-trip; callers normalise to int.
        self.class_id2label = class_id2label or {}
        self.ner_id2label = ner_id2label or {}


class FusedModel(PreTrainedModel):
    config_class = FusedConfig
    main_input_name = "input_ids"

    def __init__(self, config: FusedConfig):
        super().__init__(config)
        base_conf = AutoConfig.from_pretrained(
            config.backbone, num_labels=config.num_class_labels
        )
        # from_config = architecture only, no pretrained weights. Correct for the
        # from_pretrained() reload path (saved weights load over this). Training
        # uses new_pretrained() below to pull the real backbone weights.
        self.seq = AutoModelForSequenceClassification.from_config(base_conf)
        hidden = base_conf.hidden_size
        drop = getattr(base_conf, "hidden_dropout_prob", 0.1)
        self.dropout = nn.Dropout(drop if drop is not None else 0.1)
        self.ner_head = nn.Linear(hidden, config.num_ner_labels)

    def _init_weights(self, module):
        if isinstance(module, nn.Linear):
            module.weight.data.normal_(mean=0.0, std=0.02)
            if module.bias is not None:
                module.bias.data.zero_()

    @classmethod
    def new_pretrained(cls, config: FusedConfig):
        """Fresh model for training: pretrained backbone + classifier head,
        freshly-initialised NER head."""
        model = cls(config)
        c2i = {v: int(k) for k, v in config.class_id2label.items()}
        i2c = {int(k): v for k, v in config.class_id2label.items()}
        model.seq = AutoModelForSequenceClassification.from_pretrained(
            config.backbone,
            num_labels=config.num_class_labels,
            id2label=i2c,
            label2id=c2i,
        )
        return model

    def forward(
        self,
        input_ids=None,
        attention_mask=None,
        token_type_ids=None,
        class_labels=None,
        ner_labels=None,
        **kw,
    ):
        out = self.seq(
            input_ids=input_ids,
            attention_mask=attention_mask,
            token_type_ids=token_type_ids,
            output_hidden_states=True,
        )
        class_logits = out.logits
        last_hidden = out.hidden_states[-1]  # (batch, seq, hidden)
        ner_logits = self.ner_head(self.dropout(last_hidden))

        loss = None
        if class_labels is not None and ner_labels is not None:
            cl = F.cross_entropy(class_logits, class_labels)
            nl = F.cross_entropy(
                ner_logits.view(-1, self.config.num_ner_labels),
                ner_labels.view(-1),
            )  # ignore_index=-100 by default -> special/pad tokens skipped
            loss = self.config.class_weight * cl + self.config.ner_weight * nl

        return FusedOutput(
            loss=loss, class_logits=class_logits, ner_logits=ner_logits
        )
