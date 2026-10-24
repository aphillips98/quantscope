from __future__ import annotations

import json
import unittest
from unittest.mock import MagicMock, patch

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter
from quantscope_bench.adapters.llamacpp import LlamaCppAdapter


class FakeAdapter(ModelAdapter):
    capabilities = AdapterCapabilities(log_likelihood=True)

    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        return "A"

    def score_options(self, prompt: str, options: list[str]) -> list[float]:
        return [float(index) for index, _ in enumerate(options)]


class AdapterContractTests(unittest.TestCase):
    def test_adapter_can_generate_and_score_options(self) -> None:
        adapter = FakeAdapter()

        self.assertEqual(adapter.generate("Question"), "A")
        self.assertEqual(adapter.score_options("Question", ["A", "B"]), [0.0, 1.0])
        self.assertTrue(adapter.capabilities.log_likelihood)


class LlamaServerAdapterTests(unittest.TestCase):
    @patch("quantscope_bench.adapters.llamacpp.urlopen")
    @patch("quantscope_bench.adapters.llamacpp.subprocess.Popen")
    @patch("quantscope_bench.adapters.llamacpp.socket.socket")
    @patch("quantscope_bench.adapters.llamacpp.shutil.which", return_value="/opt/llama/bin/llama-server")
    def test_uses_module_server_and_stops_it_on_close(
        self, _which: MagicMock, socket_factory: MagicMock, popen: MagicMock, urlopen: MagicMock
    ) -> None:
        listener = socket_factory.return_value.__enter__.return_value
        listener.getsockname.return_value = ("127.0.0.1", 54321)
        process = popen.return_value
        process.poll.return_value = None
        health_response = MagicMock(status=200)
        health_response.__enter__.return_value.status = 200
        completion_response = MagicMock()
        completion_response.__enter__.return_value.read.return_value = json.dumps(
            {"content": "A"}
        ).encode()
        urlopen.side_effect = [health_response, completion_response]

        with patch.dict("os.environ", {"CUDA_VISIBLE_DEVICES": "0"}):
            adapter = LlamaCppAdapter(
                {
                    "local_path": "model.gguf",
                    "inference": {"context_size": 2048, "max_tokens": 8, "seed": 42},
                }
            )
        self.assertEqual(adapter.generate("Question"), "A")
        adapter.close()

        command = popen.call_args.args[0]
        self.assertEqual(command[0], "/opt/llama/bin/llama-server")
        self.assertIn("-1", command)
        self.assertEqual(command[command.index("--flash-attn") + 1], "off")
        self.assertTrue(urlopen.call_args_list[1].args[0].full_url.endswith("/completion"))
        payload = json.loads(urlopen.call_args_list[1].args[0].data)
        self.assertEqual(payload["n_predict"], 8)
        self.assertEqual(payload["seed"], 42)
        process.terminate.assert_called_once_with()
        self.assertEqual(len(adapter.performance_requests), 1)
        self.assertIsNone(adapter.performance_requests[0]["prompt_tokens"])

    @patch("quantscope_bench.adapters.llamacpp.time.perf_counter", side_effect=[10.0, 10.25])
    @patch("quantscope_bench.adapters.llamacpp.urlopen")
    def test_records_server_timings_without_changing_response(
        self, urlopen: MagicMock, _clock: MagicMock
    ) -> None:
        adapter = LlamaCppAdapter.__new__(LlamaCppAdapter)
        adapter._server_process = MagicMock()
        adapter._base_url = "http://localhost:1234"
        adapter._temperature = 0.0
        adapter._max_tokens = 1
        adapter._seed = None
        adapter.performance_requests = []
        urlopen.return_value.__enter__.return_value.read.return_value = json.dumps(
            {"content": " B", "timings": {"prompt_n": 100, "predicted_n": 2,
             "prompt_ms": 125, "predicted_ms": 50}}
        ).encode()

        self.assertEqual(adapter.generate("Question"), " B")
        self.assertEqual(adapter.performance_requests[0], {
            "request_id": 0, "backend": "llama-server", "latency_seconds": 0.25,
            "prompt_tokens": 100.0, "generated_tokens": 2.0,
            "prompt_seconds": 0.125, "generation_seconds": 0.05,
        })

    @patch("quantscope_bench.adapters.llamacpp.time.perf_counter", side_effect=[10.0, 10.5])
    def test_python_fallback_records_usage_without_inventing_timings(self, _clock: MagicMock) -> None:
        adapter = LlamaCppAdapter.__new__(LlamaCppAdapter)
        adapter._server_process = None
        adapter._temperature = 0.0
        adapter._max_tokens = 1
        adapter._seed = None
        adapter.performance_requests = []
        adapter._model = MagicMock()
        adapter._model.create_completion.return_value = {
            "choices": [{"text": "A"}],
            "usage": {"prompt_tokens": 80, "completion_tokens": 1},
        }
        self.assertEqual(adapter.generate("Question"), "A")
        measurement = adapter.performance_requests[0]
        self.assertEqual(measurement["latency_seconds"], 0.5)
        self.assertEqual(measurement["generated_tokens"], 1)
        self.assertIsNone(measurement["generation_seconds"])

    @patch("quantscope_bench.adapters.llamacpp.time.perf_counter", side_effect=[10.0, 10.5])
    def test_python_fallback_uses_configured_max_tokens_and_seed(self, _clock: MagicMock) -> None:
        adapter = LlamaCppAdapter.__new__(LlamaCppAdapter)
        adapter._server_process = None
        adapter._temperature = 0.0
        adapter._max_tokens = 8
        adapter._seed = 42
        adapter.performance_requests = []
        adapter._model = MagicMock()
        adapter._model.create_completion.return_value = {"choices": [{"text": "A"}]}

        self.assertEqual(adapter.generate("Question"), "A")
        adapter._model.create_completion.assert_called_once_with(
            prompt="Question", max_tokens=8, temperature=0.0, stop=["\n"], seed=42
        )

    @patch("quantscope_bench.adapters.llamacpp.time.perf_counter", side_effect=[10.0, 10.5])
    def test_generate_argument_overrides_configured_max_tokens(self, _clock: MagicMock) -> None:
        adapter = LlamaCppAdapter.__new__(LlamaCppAdapter)
        adapter._server_process = None
        adapter._temperature = 0.0
        adapter._max_tokens = 8
        adapter._seed = None
        adapter.performance_requests = []
        adapter._model = MagicMock()
        adapter._model.create_completion.return_value = {"choices": [{"text": "A"}]}

        adapter.generate("Question", max_tokens=3)

        adapter._model.create_completion.assert_called_once_with(
            prompt="Question", max_tokens=3, temperature=0.0, stop=["\n"]
        )

    @patch("quantscope_bench.adapters.llamacpp.urlopen")
    @patch("quantscope_bench.adapters.llamacpp.subprocess.Popen")
    @patch("quantscope_bench.adapters.llamacpp.shutil.which", return_value="llama-server")
    def test_flash_attention_can_be_overridden(
        self, _which: MagicMock, popen: MagicMock, urlopen: MagicMock
    ) -> None:
        popen.return_value.poll.return_value = None
        urlopen.return_value.__enter__.return_value.status = 200
        for setting, expected in (("on", "on"), ("auto", "auto"), (True, "on"), (False, "off")):
            with self.subTest(setting=setting):
                adapter = LlamaCppAdapter(
                    {"local_path": "model.gguf", "inference": {"flash_attention": setting}}
                )
                command = popen.call_args.args[0]
                self.assertEqual(command[command.index("--flash-attn") + 1], expected)
                adapter.close()

    @patch("quantscope_bench.adapters.llamacpp.subprocess.Popen")
    def test_invalid_flash_attention_is_rejected_before_launch(self, popen: MagicMock) -> None:
        with self.assertRaisesRegex(ValueError, "inference.flash_attention"):
            LlamaCppAdapter(
                {"local_path": "model.gguf", "inference": {"flash_attention": "invalid"}}
            )
        popen.assert_not_called()