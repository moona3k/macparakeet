"""MLX-LM wrapper. Loads once, generates many."""

from __future__ import annotations

import gc
import threading
import time
from typing import Optional

from .config import LLM_PROMPT


class MLXEngine:
    """Lazy-loaded MLX-LM generator. One instance per daemon process.

    Model load is deferred to first use (or explicit `warmup()`). The daemon
    can call `unload()` to drop the model after an idle period; the next
    `clean()` call will transparently reload.
    """

    def __init__(self, model_id: str):
        self.model_id = model_id
        self._model = None
        self._tokenizer = None
        self._generate = None
        self._sampler_factory = None
        self._lock = threading.Lock()
        self.last_used = time.monotonic()

    @property
    def is_loaded(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        """Load the model + tokenizer. Blocking; expected to take seconds.

        Idempotent and thread-safe: concurrent callers that both arrive while
        the model is unloaded will serialize on the lock; only one load runs.
        """
        with self._lock:
            if self._model is not None:
                return
            # Local imports so the daemon can fail gracefully if MLX is missing.
            from mlx_lm import load, generate  # type: ignore
            from mlx_lm.sample_utils import make_sampler  # type: ignore

            self._model, self._tokenizer = load(self.model_id)
            self._generate = generate
            self._sampler_factory = make_sampler

    def unload(self) -> None:
        """Drop the model. The next clean() call will reload."""
        with self._lock:
            if self._model is None:
                return
            self._model = None
            self._tokenizer = None
            # Keep references to imported callables — re-import is cheap.
        gc.collect()
        try:
            import mlx.core as mx  # type: ignore
            mx.metal.clear_cache()
        except Exception:
            pass

    def warmup(self) -> None:
        """Run a tiny generation to JIT-compile and prime caches."""
        self.load()
        _ = self.clean("Hello world.", max_tokens=8)

    def clean(self, text: str, max_tokens: int = 150, prompt: Optional[str] = None) -> str:
        """Run the cleanup prompt on `text`. Returns cleaned text only.

        If `prompt` is provided, it overrides the default cleanup prompt for
        this call (treated as the chat system message). Lets callers reuse the
        daemon as a generic local LLM endpoint instead of a cleanup-only one.
        """
        self.load()
        self.last_used = time.monotonic()

        system_prompt = prompt if prompt else LLM_PROMPT

        # Build chat-formatted prompt using the tokenizer's chat template
        # (Qwen2.5-Instruct expects this).
        messages = [
            {"role": "system", "content": system_prompt},
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
