"""Local Hugging Face Transformers adapter."""

from __future__ import annotations

from typing import Any, Sequence

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter

class TransformersAdapter(ModelAdapter):
    capabilities = AdapterCapabilities(log_likelihood=True)

    def __init__(self, model: dict[str, Any]) -> None:
        try:
            import torch
            from transformers import AutoModelForCausalLM, AutoTokenizer
        except ImportError as error:
            raise RuntimeError(
                "Transformers backend requires `pip install -e '.[transformers]'`"
            ) from error

        source = model.get("local_path") or model["hf_id"]
        inference = model.get("inference", {})
        dtype_name = inference.get("dtype")
        dtype = getattr(torch, dtype_name) if dtype_name else None
        self._torch = torch
        self._tokenizer = AutoTokenizer.from_pretrained(source)
        self._model = AutoModelForCausalLM.from_pretrained(source, torch_dtype=dtype)
        self._model.eval()
        self._device = next(self._model.parameters()).device

    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        encoded = self._tokenizer(prompt, return_tensors="pt").to(self._device)
        with self._torch.inference_mode():
            output = self._model.generate(
                **encoded,
                do_sample=False,
                max_new_tokens=max_tokens,
                pad_token_id=self._tokenizer.eos_token_id,
            )
        generated = output[0, encoded.input_ids.shape[1] :]
        return self._tokenizer.decode(generated, skip_special_tokens=True)

    def score_options(self, prompt: str, options: Sequence[str]) -> list[float]:
        return [self._score_continuation(prompt, option) for option in options]

    def _score_continuation(self, prompt: str, option: str) -> float:
        prompt_tokens = self._tokenizer(prompt, add_special_tokens=False).input_ids
        option_tokens = self._tokenizer(option, add_special_tokens=False).input_ids
        if not option_tokens:
            return float("-inf")
        input_ids = self._torch.tensor([prompt_tokens + option_tokens], device=self._device)
        with self._torch.inference_mode():
            logits = self._model(input_ids=input_ids).logits[0]
        log_probs = self._torch.log_softmax(logits, dim=-1)
        start = len(prompt_tokens)
        return sum(
            log_probs[start + offset - 1, token_id].item()
            for offset, token_id in enumerate(option_tokens)
        )