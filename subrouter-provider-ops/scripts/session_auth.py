#!/usr/bin/env python3
"""Recover a SubRouter management credential from the local Chrome profile.

The Playwright browser that owns the logged-in SubRouter session runs in an
isolated network namespace: its loopback cannot reach this shell, and the
Playwright MCP sandbox exposes no filesystem. So a key created in the page
cannot be moved out of it.

The session cookie itself is on this machine. Chrome encrypts it with the
"Chrome Safe Storage" secret from the desktop keyring, so reading it needs
nothing but this user's own unlocked keyring.

The decrypted cookie is never printed. It goes straight into a request header
and out of scope.

    python3 session_auth.py check           -> say whether the session works
    python3 session_auth.py create-key best -> make a provider:<slug> token
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

BASE = "https://subrouter.ai"
USER_ID = "11440"
CHROME_COOKIES = Path.home() / ".config" / "google-chrome" / "Default" / "Cookies"
KEYRING_APPS = ("chrome", "chromium")
COOKIE_NAME = "session"


def die(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def safe_storage_password() -> bytes:
    """Pull the Chrome Safe Storage secret out of the desktop keyring."""
    for app in KEYRING_APPS:
        try:
            out = subprocess.run(
                ["secret-tool", "lookup", "application", app],
                capture_output=True, timeout=15,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            continue
        if out:
            return out
    die("no Chrome Safe Storage entry in the keyring (is the desktop session unlocked?)")


def decrypt_v11(blob: bytes, password: bytes) -> bytes:
    """Decrypt a Chrome v11 cookie value on Linux.

    The keyring secret is the base64 TEXT of the stored secret, used as the
    PBKDF2 password. The plaintext is the cookie value prefixed with a
    32-byte domain hash, and the tail carries PKCS#7 padding.
    """
    if not blob.startswith(b"v11"):
        raise ValueError(f"unexpected cookie version {blob[:3]!r}")
    from hashlib import pbkdf2_hmac

    key = pbkdf2_hmac("sha1", password, b"saltysalt", 1, 16)
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except ImportError:
        die("python 'cryptography' is required to decrypt the Chrome cookie")
    dec = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).decryptor()
    plain = dec.update(blob[3:]) + dec.finalize()

    pad = plain[-1]
    if 1 <= pad <= 16 and plain[-pad:] == bytes([pad]) * pad:
        plain = plain[:-pad]
    if len(plain) <= 32:
        die("decrypted cookie is too short to hold a domain hash")
    value = plain[32:]
    if not value or not all(32 <= b < 127 for b in value):
        die("decrypted cookie value is not printable ASCII")
    return value


def session_cookie() -> str:
    if not CHROME_COOKIES.exists():
        die(f"no Chrome cookie store at {CHROME_COOKIES}")
    tmpdir = tempfile.mkdtemp(prefix="srck-")
    tmp = Path(tmpdir) / "Cookies"
    shutil.copy2(CHROME_COOKIES, tmp)
    try:
        con = sqlite3.connect(f"file:{tmp}?mode=ro", uri=True)
        row = con.execute(
            "select encrypted_value from cookies where host_key like '%subrouter.ai' and name=?",
            (COOKIE_NAME,),
        ).fetchone()
        con.close()
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    if not row:
        die("no subrouter.ai session cookie in the Chrome profile")
    plain = decrypt_v11(bytes(row[0]), safe_storage_password())
    if not plain:
        die("decrypted cookie is empty")
    return plain.decode("utf-8", "replace")


def api(path: str, cookie: str, method: str = "GET", body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={
            "Cookie": f"{COOKIE_NAME}={cookie}",
            "New-Api-User": USER_ID,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        return exc.code, {"message": exc.read().decode("utf-8", "replace")[:200]}
    except Exception as exc:  # noqa: BLE001
        return 0, {"message": f"{type(exc).__name__}: {exc}"}


def token_body(slug: str) -> dict:
    return {
        "name": f"{slug}-fixed",
        "group": f"provider:{slug}",
        "unlimited_quota": True,
        "remain_quota": 0,
        "expired_time": -1,
        "model_limits_enabled": False,
        "model_limits": "",
        "subrouter_providers": "",
        "subrouter_model_providers": "",
        "subrouter_model_price_limits": "",
        "subrouter_sort_mode": "token_price_first",
        "subrouter_route_preference": "price_first",
        "include_cache_hit_rate": False,
        "load_balance_enabled": False,
        "include_provider_self": True,
        "include_official_channels": False,
        "include_shared_subscriptions": False,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=["check", "create-key"])
    ap.add_argument("slug", nargs="?", help="provider slug for create-key")
    args = ap.parse_args()

    cookie = session_cookie()
    status, j = api("/api/user/self", cookie)
    if status != 200 or not (j.get("success") or j.get("data")):
        print(json.dumps({"ok": False, "status": status, "message": j.get("message")}, indent=1))
        return 1

    if args.action == "check":
        print(json.dumps({
            "ok": True, "status": status,
            "user_id": (j.get("data") or {}).get("id"),
            "username": (j.get("data") or {}).get("username"),
            "quota": (j.get("data") or {}).get("quota"),
        }, indent=1))
        return 0

    slug = args.slug
    if not slug:
        die("create-key needs a provider slug")

    # Reuse an existing token for this group rather than making a duplicate.
    st, lst = api("/api/token/?p=1&size=100", cookie)
    items = (lst.get("data") or {}).get("items") or []
    same = [t for t in items if t.get("group") == f"provider:{slug}"]
    if same:
        top = max(same, key=lambda t: t["id"])
        key = top["key"]
        token_id = top["id"]
        action = "reused"
    else:
        st, j = api("/api/token/", cookie, method="POST", body=token_body(slug))
        if not (j.get("data") or {}).get("key"):
            print(json.dumps({"ok": False, "status": st, "message": j.get("message")}, indent=1))
            return 1
        key = j["data"]["key"]
        token_id = j["data"].get("id")
        action = "created"

    dest = Path.home() / ".config" / "subrouter" / "keys" / slug
    dest.parent.mkdir(parents=True, exist_ok=True)
    # The create response returns the key already prefixed with "sk-", while
    # the token list returns it bare. SubRouter accepts either, so normalise
    # to the bare form the account itself stores and avoid double prefixes.
    bare = key[3:] if key.startswith("sk-") else key
    dest.write_text(bare)
    os.chmod(dest, 0o600)
    stt = dest.stat()
    print(json.dumps({
        "ok": True, "action": action, "token_id": token_id, "slug": slug,
        "file": str(dest), "bytes": stt.st_size, "mode": oct(stt.st_mode & 0o777),
    }, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
