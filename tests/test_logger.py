import logging
import pytest
from pathlib import Path


def test_logger_creates_log_file(tmp_path):
    from service.logger import get_logger
    log_path = tmp_path / "logs" / "test.log"
    logger = get_logger("test", log_path=log_path)
    logger.info("hello")
    assert log_path.exists()
    assert "hello" in log_path.read_text()


def test_logger_includes_component_name(tmp_path):
    from service.logger import get_logger
    log_path = tmp_path / "logs" / "test.log"
    logger = get_logger("my_component", log_path=log_path)
    logger.info("test message")
    content = log_path.read_text()
    assert "my_component" in content


def test_logger_respects_level(tmp_path):
    from service.logger import get_logger
    log_path = tmp_path / "logs" / "test.log"
    logger = get_logger("test_level", log_path=log_path, level="error")
    logger.info("should not appear")
    logger.error("should appear")
    content = log_path.read_text()
    assert "should not appear" not in content
    assert "should appear" in content


def test_logger_does_not_duplicate_handlers(tmp_path):
    from service.logger import get_logger
    log_path = tmp_path / "logs" / "test.log"
    logger = get_logger("dup_test", log_path=log_path)
    logger2 = get_logger("dup_test", log_path=log_path)
    assert logger is logger2
    assert len(logger.handlers) <= 2  # file + console max
