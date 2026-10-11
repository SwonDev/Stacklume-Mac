"""HTTP de medios públicos: DNS verificado y conexión fijada a la IP comprobada."""
from __future__ import annotations

import http.client
import ipaddress
import socket
import ssl
from urllib.parse import urlsplit, urljoin, quote

from .inputs import InputError


def destination(url: str) -> tuple[str, str, int, str, str]:
    try:
        parsed = urlsplit(url)
        port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
    except ValueError as exc:
        raise InputError("La URL del medio no es válida") from exc
    if not 1 <= port <= 65535:
        raise InputError("El puerto del medio no es válido")
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username is not None or parsed.password is not None:
        raise InputError("El medio debe usar una URL HTTP pública sin credenciales")
    if any(ord(c) < 33 or ord(c) == 127 for c in url):
        raise InputError("La URL del medio contiene caracteres no válidos")
    try:
        answers = socket.getaddrinfo(parsed.hostname, port, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise InputError("No se pudo resolver el dominio del medio") from exc
    addresses = [answer[4][0] for answer in answers]
    if not addresses:
        raise InputError("El dominio no contiene direcciones públicas")
    for address in addresses:
        ip = ipaddress.ip_address(address)
        if not ip.is_global or ip.is_multicast or ip.is_reserved or ip.is_unspecified or (getattr(ip, "ipv4_mapped", None) and not ip.ipv4_mapped.is_global):
            raise InputError("No se descargan medios de direcciones privadas o locales")
    target = quote(parsed.path or "/", safe="/%:@!$&'()*+,;=-._~")
    if parsed.query:
        target += "?" + quote(parsed.query, safe="/%?:@!$&'()*+,;=-._~")
    return parsed.scheme, parsed.hostname, port, addresses[0], target


class PinnedConnection(http.client.HTTPConnection):
    def __init__(self, host: str, port: int, address: str, secure: bool):
        super().__init__(host, port, timeout=60)
        self.address = address
        self.secure = secure

    def connect(self) -> None:
        # Nunca vuelve a resolver el hostname validado; TLS conserva SNI y certificado del dominio original.
        self.sock = socket.create_connection((self.address, self.port), self.timeout)
        if self.secure:
            self.sock = ssl.create_default_context().wrap_socket(self.sock, server_hostname=self.host)


def open_public(url: str) -> tuple[PinnedConnection, http.client.HTTPResponse]:
    current = url
    for _ in range(6):
        scheme, host, port, address, target = destination(current)
        conn = PinnedConnection(host, port, address, scheme == "https")
        try:
            conn.request("GET", target, headers={"Accept-Encoding": "identity", "User-Agent": "Stacklume/EmbeddingGemma"})
            response = conn.getresponse()
        except Exception:
            conn.close()
            raise
        if response.status in (301, 302, 303, 307, 308):
            location = response.getheader("Location")
            response.close()
            conn.close()
            if not location:
                raise InputError("La redirección del medio no contiene un destino")
            current = urljoin(current, location)
            continue
        if not 200 <= response.status < 300:
            response.close()
            conn.close()
            raise InputError("El servidor del medio devolvió un error HTTP")
        return conn, response
    raise InputError("El medio contiene demasiadas redirecciones")
