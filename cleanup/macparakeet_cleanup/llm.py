"""MLX-LM wrapper. Loads once, generates many."""

from __future__ import annotations

import time
from typing import Optional

from .config import LLM_PROMPT


class MLXEngine:
    """Lazy-loaded MLX-LM generator. One instance per daemon process."""

    def __init__(self, model_id: str):
        self.model_id = model_id
        self._model = None
        self._tokenizer = None
        self._generate = None
        self._sampler_factory = None

    def load(self) -> None:
        """Load the model + tokenizer. Blocking; expected to take seconds."""
        if self._model is not None:
            return
        # Imports are local so the daemon can fail gracefully if MLX is missing.
        from mlx_lm import load, generate  # type: ignore
        from mlx_lm.sample_utils import make_sampler  # type: ignore

        self._model, self._tokenizer = load(self.model_id)
        self._generate = generate
        self._sampler_factory = make_sampler

    def warmup(self) -> None:
        """Run a tiny generation to JIT-compile and prime caches."""
        self.load()
        _ = self.clean("Hello world.", max_tokens=8)

    def clean(self, text: str, max_tokens: int = 150) -> str:
        """Run the cleanup prompt on `text`. Returns cleaned text only."""
        if self._model is None:
            self.load()

        # Build chat-formatted prompt using the tokenizer's chat template
        # (Qwen2.5-Instruct expects this).
        messages = [
            {"role": "system", "content": LLM_PROMPT},
            {"role": "user", "content": text},
        ]
        prompt = self._tokenizer.apply_chat_template(  # type: ignore[union-attr]
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )

        sampler = self._sampler_factory(temp=0.0)  # type: ignore[misc]
        out = self._generate(  # type: ignore[misc]
            self._model,
            self._tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=sampler,
            verbose=False,
        )
        return out.strip()
