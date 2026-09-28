import logging
import os

from leonardd import __main__ as main_mod


def test_parse_args_defaults(tmp_path, monkeypatch):
    monkeypatch.delenv("LEONARD_MODEL", raising=False)
    args = main_mod.parse_args(["--data-dir", str(tmp_path)])
    assert args.model == main_mod.DEFAULT_MODEL
    assert args.floor is None
    assert args.parent_pid is None


def test_second_daemon_on_the_same_data_cannot_take_the_lock(tmp_path):
    first = main_mod.acquire_lock(tmp_path)
    assert first is not None
    assert main_mod.acquire_lock(tmp_path) is None
    first.close()
    again = main_mod.acquire_lock(tmp_path)
    assert again is not None
    again.close()


def test_parent_watchdog():
    assert main_mod.parent_alive(os.getppid())
    assert not main_mod.parent_alive(999_999_999 if os.getppid() != 999_999_999 else 1)


def test_file_logging_is_configured(tmp_path):
    log = tmp_path / "logs" / "leonardd.log"
    main_mod.configure_logging("INFO", str(log))
    logging.getLogger("leonardd").info("hello")
    for handler in logging.getLogger().handlers:
        handler.flush()
    assert "hello" in log.read_text()
    main_mod.configure_logging("WARNING", None)
