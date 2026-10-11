#!/usr/bin/env python3
"""Regresiones sin modelos, sockets ni descargas del runtime distribuido."""
import io
import ast
import os
import secrets
import socket
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Runtime/EmbeddingGemma"))
from egemma.access import api_key, identity_proof, local_file_path, open_local_file
from egemma.config import Config
from egemma.files import list_candidates, read_text_file
from egemma.inputs import InputError
from egemma.public_http import destination, open_public, PinnedConnection
from egemma.server import create_app
from egemma.client import Client, ServiceError
from egemma.media import MediaResolver
from fastapi.testclient import TestClient
import httpx


class RuntimeBoundaries(unittest.TestCase):
    def test_private_key_persists_and_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"EGEMMA_HOME": folder}, clear=True):
            key = api_key()
            self.assertEqual(key, api_key())
            path = Path(folder) / "api-token"
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.rename(path.with_suffix(".old"))
            path.symlink_to(path.with_suffix(".old"))
            with self.assertRaises(OSError):
                api_key()

    def test_health_public_minimum_and_authenticated_details(self):
        service = Mock()
        service.status.return_value = {"collections": ["privada"], "path": "/privado", "engine": {"loaded": False}}
        key = "k" * 64
        with TestClient(create_app(Config(), service, api_key=key), base_url="http://127.0.0.1:8737") as client:
            self.assertEqual(client.get("/health").json(), {"service": "embeddinggemma-2"})
            nonce = secrets.token_hex(32)
            body = client.get("/health", params={"challenge": nonce}).json()
            self.assertEqual(body["proof"], identity_proof(key, nonce))
            self.assertNotIn("path", body)
            self.assertEqual(client.get("/collections").status_code, 401)
            self.assertEqual(client.post("/shutdown").status_code, 401)
            self.assertEqual(client.get("/health", headers={"Authorization": "Bearer " + key}).json()["collections"], ["privada"])
            self.assertEqual(client.get("/health", params={"challenge": "bad"}).status_code, 400)
        with self.assertRaises(ValueError):
            create_app(Config(), service)

    def test_fake_port_never_receives_bearer(self):
        requests = []
        def fake(request):
            requests.append(request)
            return httpx.Response(200, json={"service": "embeddinggemma-2", "proof": "0" * 64})
        with patch.dict(os.environ, {"EGEMMA_API_KEY": "k" * 64}), Client(Config()) as client:
            client.http.close()
            client.http = httpx.Client(base_url=client.base_url, headers={"Authorization": "Bearer " + client.key}, transport=httpx.MockTransport(fake))
            with self.assertRaises(ServiceError):
                client.health()
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].headers.get("Authorization"), "")

    def test_real_identity_keeps_authenticated_health(self):
        key = "k" * 64
        def real(request):
            if request.url.params.get("challenge"):
                self.assertEqual(request.headers.get("Authorization"), "")
                return httpx.Response(200, json={"service": "embeddinggemma-2", "proof": identity_proof(key, request.url.params["challenge"])})
            self.assertEqual(request.headers["Authorization"], "Bearer " + key)
            return httpx.Response(200, json={"service": "embeddinggemma-2", "engine": {"loaded": False}})
        with patch.dict(os.environ, {"EGEMMA_API_KEY": key}), Client(Config()) as client:
            client.http.close()
            client.http = httpx.Client(base_url=client.base_url, headers={"Authorization": "Bearer " + key}, transport=httpx.MockTransport(real))
            self.assertFalse(client.health()["engine"]["loaded"])

    def test_paths_and_git_symlink_escape(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve() / "repo"
            root.mkdir()
            safe = root / "normal.txt"
            safe.write_text("Texto permitido")
            secret = root / ".env"
            secret.write_text("dato sintético")
            link = root / "disfraz.txt"
            link.symlink_to(secret)
            outside = root.parent / "externo.txt"
            outside.write_text("externo")
            for value in (str(root / "api-token"), str(secret), str(link), "file://servidor/recurso.png", "//servidor/recurso.png"):
                with self.subTest(value=value), self.assertRaises(InputError):
                    local_file_path(value)
            with patch("egemma.files._git_files", return_value=[safe, secret, link, outside]):
                self.assertEqual([c.path for c in list_candidates(root)], [safe])
            self.assertEqual(read_text_file(safe, 100), "Texto permitido")
            self.assertIsNone(read_text_file(safe, 2))
            self.assertEqual(local_file_path(safe.as_uri()), safe)

    def test_open_does_not_follow_symlink_inserted_after_check(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            file = root / "normal.txt"
            file.write_text("normal")
            other = root / "other.txt"
            other.write_text("other")
            real = local_file_path
            def checked_then_swapped(source):
                result = real(source)
                file.unlink()
                file.symlink_to(other)
                return result
            with patch("egemma.access.local_file_path", side_effect=checked_then_swapped), self.assertRaises(OSError):
                open_local_file(file)

    def test_special_file_is_rejected_without_waiting(self):
        with tempfile.TemporaryDirectory() as folder:
            fifo = Path(folder).resolve() / "canal.txt"
            os.mkfifo(fifo)
            with self.assertRaises(InputError):
                open_local_file(fifo)

    def test_normalized_media_aliases_reject_credentials_before_worker(self):
        from egemma.service import Service
        service = object.__new__(Service)
        service.engine = Mock()
        with tempfile.TemporaryDirectory() as folder:
            forbidden = str(Path(folder).resolve() / ".env")
            inputs = [{"image": forbidden}, {"content": [{"type": "image_url", "image_url": {"url": forbidden}}]}, {"pdf": {"src": forbidden, "page": 1}}, {"audio": {"path": forbidden}}]
            for raw in inputs:
                with self.subTest(raw=raw), self.assertRaises(InputError):
                    service.embed(raw)
        service.engine.encode.assert_not_called()

    def test_media_local_and_data_uri_still_work(self):
        with tempfile.TemporaryDirectory() as folder, MediaResolver(100) as resolver:
            path = Path(folder).resolve() / "normal.png"
            path.write_bytes(b"fixture")
            self.assertEqual(Path(resolver.local_path(path.as_uri())).read_bytes(), b"fixture")
            data = resolver.local_path("data:image/png;base64,Zml4dHVyZQ==")
            self.assertEqual(Path(data).read_bytes(), b"fixture")

    def test_pdf_index_reads_safe_descriptor_without_model(self):
        from egemma.indexer import Indexer
        from egemma.files import Candidate
        tree = ast.parse((Path(__file__).parent / "runtime_smoke.py").read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "pdf")
        namespace = {}
        exec(compile(ast.Module(body=[function], type_ignores=[]), "fixture_pdf", "exec"), namespace)
        indexer = object.__new__(Indexer)
        indexer.cfg = Config(modalities=["text"])
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder).resolve() / "documento.pdf"
            file.write_bytes(namespace["pdf"](") Tj 0 -24 Td (".join(["Documento de prueba local, sin datos personales."] * 6)))
            candidate = Candidate(file, "pdf", file.stat().st_size, file.stat().st_mtime, False)
            units = indexer._plan_pdf(candidate, "documento.pdf")
            self.assertTrue(units)
            self.assertTrue(any("Documento de prueba" in unit.item["parts"][0]["text"] for unit in units))

    def test_private_alternate_dns_forms_and_mixed_answers(self):
        for value in ("127.0.0.1", "10.0.0.1", "169.254.169.254", "::1", "::ffff:127.0.0.1", "224.0.0.1"):
            answers = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (value, 80))]
            with self.subTest(value=value), patch("egemma.public_http.socket.getaddrinfo", return_value=answers), self.assertRaises(InputError):
                destination("http://example.test/a")
        answers = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 80)) for address in ("8.8.8.8", "127.0.0.1")]
        with patch("egemma.public_http.socket.getaddrinfo", return_value=answers), self.assertRaises(InputError):
            destination("http://example.test/a")

    def test_public_unicode_url_and_invalid_port(self):
        answers = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("8.8.8.8", 443))]
        with patch("egemma.public_http.socket.getaddrinfo", return_value=answers):
            self.assertEqual(destination("https://example.test/niño.png?q=año")[4], "/ni%C3%B1o.png?q=a%C3%B1o")
            with self.assertRaises(InputError):
                destination("https://example.test:0/a")

    def test_public_request_pins_address_tls_name_and_redirect(self):
        fake_socket = Mock()
        context = Mock()
        with patch("egemma.public_http.socket.create_connection", return_value=fake_socket) as connect, patch("egemma.public_http.ssl.create_default_context", return_value=context):
            connection = PinnedConnection("example.test", 443, "8.8.8.8", True)
            connection.connect()
            connect.assert_called_once_with(("8.8.8.8", 443), 60)
            context.wrap_socket.assert_called_once_with(fake_socket, server_hostname="example.test")
        response = Mock(status=302)
        response.getheader.return_value = "http://127.0.0.1/private"
        conn = Mock()
        conn.getresponse.return_value = response
        def dns(host, port, **kwargs):
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("8.8.8.8" if host == "example.test" else "127.0.0.1", port))]
        with patch("egemma.public_http.socket.getaddrinfo", side_effect=dns), patch("egemma.public_http.PinnedConnection", return_value=conn), self.assertRaises(InputError):
            open_public("https://example.test/media")
        conn.close.assert_called()

    def test_download_limit_and_cleanup(self):
        response = Mock()
        response.getheader.return_value = None
        response.read.side_effect = [b"safe", b""]
        with MediaResolver(8) as resolver, patch("egemma.public_http.open_public", return_value=(Mock(), response)):
            self.assertEqual(Path(resolver.local_path("https://example.test/a.png")).read_bytes(), b"safe")
        response.read.side_effect = [b"too much data"]
        with MediaResolver(8) as resolver, patch("egemma.public_http.open_public", return_value=(Mock(), response)):
            with self.assertRaises(InputError):
                resolver.local_path("https://example.test/a.png")
            self.assertEqual(list(Path(resolver._tmp.name).iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
