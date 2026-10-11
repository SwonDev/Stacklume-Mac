"""Mensajes entre el servidor y el worker del modelo: longitud de 4 bytes + pickle.

pickle es seguro aquí: el canal son las tuberías anónimas (stdin/stdout) entre el servidor y el
proceso hijo que él mismo lanza; ningún tercero puede escribir en ellas. Lo que llega por HTTP nunca
se deserializa con pickle.
"""

from __future__ import annotations

import pickle
import struct
from typing import IO, Any

_HEADER = struct.Struct(">I")


def send(stream: IO[bytes], message: Any) -> None:
    payload = pickle.dumps(message, protocol=pickle.HIGHEST_PROTOCOL)
    stream.write(_HEADER.pack(len(payload)))
    stream.write(payload)
    stream.flush()


def recv(stream: IO[bytes]) -> Any:
    header = _read_exact(stream, _HEADER.size)
    (length,) = _HEADER.unpack(header)
    return pickle.loads(_read_exact(stream, length))


def _read_exact(stream: IO[bytes], size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining:
        block = stream.read(remaining)
        if not block:
            raise EOFError("el otro extremo cerró la conexión")
        chunks.append(block)
        remaining -= len(block)
    return b"".join(chunks)
