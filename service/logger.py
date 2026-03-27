import logging
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path

DEFAULT_LOG_DIR = Path.home() / ".audio-transcribe" / "logs"
DEFAULT_LOG_FILE = DEFAULT_LOG_DIR / "transcribe-service.log"


def get_logger(
    name: str,
    level: str = "info",
    log_path: Path = DEFAULT_LOG_FILE,
) -> logging.Logger:
    """Return a named logger writing to log_path with daily rotation (7 days).

    Safe to call multiple times with the same name — returns existing logger.
    """
    logger = logging.getLogger(name)

    if logger.handlers:
        return logger

    logger.setLevel(getattr(logging, level.upper(), logging.INFO))
    log_path.parent.mkdir(parents=True, exist_ok=True)

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    file_handler = TimedRotatingFileHandler(
        str(log_path), when="midnight", backupCount=7, encoding="utf-8"
    )
    file_handler.setFormatter(fmt)
    logger.addHandler(file_handler)

    console_handler = logging.StreamHandler()
    console_handler.setFormatter(fmt)
    logger.addHandler(console_handler)

    return logger
