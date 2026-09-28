import datetime as dt
import json
from pathlib import Path

import pytest

import license_tool as lt

DEV_KEY = Path(__file__).with_name("dev-signing.key")
DEV_PUBLIC = "pKVQLNy-XRirFvGnkNLtDBOHwpeMoz81bSN3RwGKy08"


def test_issue_and_verify_round_trip(tmp_path):
    public = lt.keygen(tmp_path / "k.key")
    private = lt.load_private(tmp_path / "k.key")
    key = lt.issue(private, name="Studio Rossi", email="m@x.it", edition="pro", seats=3, issued=dt.date(2026, 9, 28))
    payload = lt.verify(key, public)
    assert payload["updates_until"] == "2027-09-28"
    assert payload["seats"] == 3 and payload["v"] == 1


def test_tampering_is_detected(tmp_path):
    public = lt.keygen(tmp_path / "k.key")
    key = lt.issue(lt.load_private(tmp_path / "k.key"), name="A", email="a@b.c", edition="personal", seats=1)
    body, sig = key[len(lt.PREFIX):].split(".")
    forged_payload = json.loads(lt.unb64url(body)) | {"edition": "team", "seats": 99}
    forged = lt.PREFIX + lt.b64url(json.dumps(forged_payload, separators=(",", ":")).encode()) + "." + sig
    with pytest.raises(Exception):
        lt.verify(forged, public)


def test_keygen_never_overwrites(tmp_path):
    lt.keygen(tmp_path / "k.key")
    with pytest.raises(SystemExit):
        lt.keygen(tmp_path / "k.key")


def test_leap_day_licenses_get_a_valid_end_date(tmp_path):
    lt.keygen(tmp_path / "k.key")
    key = lt.issue(lt.load_private(tmp_path / "k.key"), name="A", email="a@b.c", edition="personal", seats=1,
                   issued=dt.date(2028, 2, 29))
    assert json.loads(lt.unb64url(key[len(lt.PREFIX):].split(".")[0]))["updates_until"] == "2029-02-28"


def test_the_committed_development_key_matches_the_apps_development_public_key():
    assert lt.public_b64(lt.load_private(DEV_KEY)) == DEV_PUBLIC
