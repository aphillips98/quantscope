from __future__ import annotations

import io
import logging
import sys
import unittest
from unittest.mock import patch

from quantscope_bench.cli import build_parser
from quantscope_bench.logging_config import (
    LEVEL_COLORS,
    LOG_FORMAT,
    LOG_LEVELS,
    ColorFormatter,
    configure_logging,
)


class LoggingTests(unittest.TestCase):
    def test_colors_for_every_level_and_plain_output(self) -> None:
        for level_name in LOG_LEVELS:
            with self.subTest(level=level_name):
                level = getattr(logging, level_name)
                record = logging.LogRecord("test", level, __file__, 1, "message %s", ("value",), None)
                plain = logging.Formatter(LOG_FORMAT).format(record)
                self.assertEqual(ColorFormatter().format(record), plain)
                self.assertEqual(
                    ColorFormatter(use_color=True).format(record),
                    f"{LEVEL_COLORS[level]}{plain}\033[0m",
                )
                self.assertEqual(record.levelname, level_name)
                self.assertEqual(logging.Formatter(LOG_FORMAT).format(record), plain)

    def test_exception_details_are_preserved(self) -> None:
        try:
            raise ValueError("test failure")
        except ValueError:
            record = logging.LogRecord(
                "test", logging.ERROR, __file__, 1, "failed", (), sys.exc_info()
            )
        formatted = ColorFormatter(use_color=True).format(record)
        self.assertIn("Traceback", formatted)
        self.assertIn("ValueError: test failure", formatted)
        self.assertTrue(formatted.endswith("\033[0m"))

    def test_color_detection(self) -> None:
        for terminal, environment, expected in (
            (True, {"TERM": "xterm"}, True),
            (False, {"TERM": "xterm"}, False),
            (True, {"NO_COLOR": "", "TERM": "xterm"}, False),
            (True, {"TERM": "dumb"}, False),
        ):
            with self.subTest(terminal=terminal, environment=environment):
                stream = io.StringIO()
                with (
                    patch.object(stream, "isatty", return_value=terminal),
                    patch("sys.stderr", stream),
                    patch.dict("os.environ", environment, clear=True),
                    patch("logging.basicConfig") as basic_config,
                ):
                    configure_logging("DEBUG")
                handler = basic_config.call_args.kwargs["handlers"][0]
                self.assertIs(handler.stream, stream)
                handler.emit(logging.LogRecord("test", logging.DEBUG, __file__, 1, "hello", (), None))
                self.assertEqual("\033[" in stream.getvalue(), expected)

    def test_thresholds_remain_unchanged(self) -> None:
        for level_name in LOG_LEVELS:
            with self.subTest(level=level_name):
                stream = io.StringIO()
                with patch("sys.stderr", stream), patch("logging.basicConfig") as basic_config:
                    configure_logging(level_name)
                settings = basic_config.call_args.kwargs
                logger = logging.Logger("test", settings["level"])
                logger.addHandler(settings["handlers"][0])
                for candidate in LOG_LEVELS:
                    logger.log(getattr(logging, candidate), "emitted-%s", candidate)
                output = stream.getvalue()
                for candidate in LOG_LEVELS:
                    self.assertEqual(
                        f"emitted-{candidate}" in output,
                        getattr(logging, candidate) >= getattr(logging, level_name),
                    )

    def test_invalid_level_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unsupported log level"):
            configure_logging("TRACE")

    def test_existing_logging_configuration_is_preserved(self) -> None:
        root = logging.RootLogger(logging.WARNING)
        handler = logging.StreamHandler(io.StringIO())
        formatter = logging.Formatter("%(message)s")
        handler.setFormatter(formatter)
        root.addHandler(handler)
        with patch("logging.root", root):
            configure_logging("DEBUG")
        self.assertEqual(root.level, logging.WARNING)
        self.assertEqual(root.handlers, [handler])
        self.assertIs(handler.formatter, formatter)

    def test_cli_levels_and_default_are_preserved(self) -> None:
        parser = build_parser()
        for command in ("run", "validate"):
            arguments = [
                command, "--models", "models.yml", "--campaign", "campaign.yml",
                "--hardware", "hardware.yml",
            ]
            if command == "run":
                arguments.extend(["--output-dir", "artifacts"])
            with self.subTest(command=command):
                self.assertEqual(parser.parse_args(arguments).log_level, "CRITICAL")
                for level_name in LOG_LEVELS:
                    self.assertEqual(
                        parser.parse_args([*arguments, "--log-level", level_name]).log_level,
                        level_name,
                    )
