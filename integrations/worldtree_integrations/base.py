"""Connector framework: polite HTTP with rate limits, robots.txt, retries and
explicit 'blocked' handling. Connectors never bypass logins, paywalls or CAPTCHAs."""
from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from dataclasses import dataclass, field
from typing import Callable, Optional

USER_AGENT = "WorldTreeAI/1.0 (self-hosted genealogy research; https://github.com/WORLD-TREE-AI)"


class ConnectorError(Exception):
    retryable = True


class BlockedError(ConnectorError):
    """Access denied, login/CAPTCHA/paywall, or disallowed by robots/terms. Never retried around."""
    retryable = False


class BudgetExceeded(ConnectorError):
    retryable = False


Transport = Callable[[str, dict], tuple[int, bytes]]


def urllib_transport(url: str, headers: dict) -> tuple[int, bytes]:
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read() if hasattr(e, "read") else b""
    except urllib.error.URLError as e:
        raise ConnectorError(f"network error: {e.reason}") from e


@dataclass
class RateLimiter:
    per_second: float
    _next: float = 0.0
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def wait(self) -> None:
        with self._lock:
            now = time.monotonic()
            if now < self._next:
                time.sleep(self._next - now)
            self._next = max(now, self._next) + 1.0 / self.per_second


class HttpClient:
    def __init__(self, name: str, per_second: float = 1.0, transport: Optional[Transport] = None,
                 check_robots: bool = False, on_request: Optional[Callable[[], None]] = None):
        self.name = name
        self.limiter = RateLimiter(per_second)
        self.transport = transport or urllib_transport
        self.check_robots = check_robots
        self.on_request = on_request  # budget accounting hook
        self._robots: dict[str, urllib.robotparser.RobotFileParser] = {}
        self.requests = 0

    def _allowed(self, url: str) -> bool:
        if not self.check_robots:
            return True  # documented APIs: governed by API terms rather than robots.txt
        p = urllib.parse.urlparse(url)
        base = f"{p.scheme}://{p.netloc}"
        if base not in self._robots:
            rp = urllib.robotparser.RobotFileParser()
            try:
                status, body = self.transport(base + "/robots.txt", {"User-Agent": USER_AGENT})
                rp.parse(body.decode("utf-8", "replace").splitlines() if status == 200 else [])
            except ConnectorError:
                rp.parse([])
            self._robots[base] = rp
        return self._robots[base].can_fetch(USER_AGENT, url)

    def get(self, url: str, params: Optional[dict] = None, retries: int = 3) -> bytes:
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        if not self._allowed(url):
            raise BlockedError(f"{self.name}: disallowed by robots.txt: {url}")
        headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
        for attempt in range(retries + 1):
            if self.on_request:
                self.on_request()
            self.limiter.wait()
            self.requests += 1
            status, body = self.transport(url, headers)
            if status == 200:
                low = body[:2000].lower()
                if b"captcha" in low or b"g-recaptcha" in low:
                    raise BlockedError(f"{self.name}: CAPTCHA encountered — not bypassed")
                return body
            if status in (401, 402, 403):
                raise BlockedError(f"{self.name}: HTTP {status} (login/paywall/forbidden) — not bypassed")
            if status in (429, 500, 502, 503, 504) and attempt < retries:
                time.sleep(min(30, 2 ** attempt))
                continue
            raise ConnectorError(f"{self.name}: HTTP {status} for {url}")
        raise ConnectorError(f"{self.name}: retries exhausted")

    def get_json(self, url: str, params: Optional[dict] = None):
        return json.loads(self.get(url, params))


@dataclass
class PersonRecord:
    """Normalized record a connector returns. Only genealogical fields — no contact data."""
    source: str
    external_id: str
    name: str
    given: str = ""
    surname: str = ""
    sex: str = "U"
    birth_year: Optional[int] = None   # astronomical
    death_year: Optional[int] = None
    birth_date: Optional[str] = None
    death_date: Optional[str] = None
    birth_place: Optional[str] = None
    death_place: Optional[str] = None
    description: str = ""
    is_public_figure: bool = False
    url: str = ""
    # relation -> list of (external_id, referenced: bool)
    relatives: dict[str, list[tuple[str, bool]]] = field(default_factory=dict)
    cross_ids: dict[str, str] = field(default_factory=dict)
    aliases: list[str] = field(default_factory=list)
    birth_name: Optional[str] = None
    is_creator: bool = False
    retrieved_at: str = field(default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))


@dataclass
class ConnectorInfo:
    id: str
    name: str
    status: str          # implemented | requires_credentials | planned
    notes: str
