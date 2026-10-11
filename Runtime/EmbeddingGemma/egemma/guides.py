"""Guías del paquete (skill y referencias): una sola fuente para la skill, el MCP y `/llms.txt`."""

from __future__ import annotations

import re
from importlib import resources
from pathlib import Path

SKILL_DIR = Path(str(resources.files("egemma") / "integrations" / "skill"))

FILES = {
    "skill": SKILL_DIR / "SKILL.md",
    "api": SKILL_DIR / "reference" / "api.md",
    "apps": SKILL_DIR / "reference" / "integracion-apps.md",
}

# Tema → palabras que identifican su sección (## …) en integracion-apps.md
TOPICS: dict[str, tuple[str, ...]] = {
    "node": ("## 1.",),
    "python": ("## 1.",),
    "multimodal": ("## 1.",),
    "service": ("## 1.",),
    "browser": ("## 2.",),
    "llama.cpp": ("## 3.",),
    "android": ("## 4.",),
    "apple": ("## 4.",),
    "patterns": ("## Patrones",),
}


def read(name: str) -> str:
    try:
        return FILES[name].read_text(encoding="utf-8")
    except KeyError as exc:
        raise ValueError(f"guía desconocida «{name}»: usa {', '.join(FILES)}") from exc


def _strip_front_matter(text: str) -> str:
    return re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)


def integration_guide(topic: str = "all") -> str:
    """Guía de integración entera o la parte de un tema, siempre con la tabla de decisión inicial."""
    topic = (topic or "all").strip().lower()
    if topic == "api":
        return read("api")
    text = read("apps")
    if topic == "all":
        return text
    if topic not in TOPICS:
        raise ValueError(f"tema desconocido «{topic}»: usa all, api, {', '.join(TOPICS)}")
    sections = re.split(r"(?m)^(?=## )", text)
    intro = sections[0]
    wanted = [s for s in sections[1:] if s.startswith(TOPICS[topic])]
    return intro + "".join(wanted)


def llms_txt(base_url: str) -> str:
    """Descripción en texto plano para cualquier LLM que llegue al servidor (convención llms.txt)."""
    skill = _strip_front_matter(read("skill"))
    return (
        "# EmbeddingGemma 2 local (egemma)\n\n"
        f"> Servicio de embeddings multimodales en {base_url}. API compatible con OpenAI en {base_url}/v1 "
        "(modelo `embeddinggemma-2`, tarea con sufijo `:query`/`:document`). Guías completas: "
        f"{base_url}/guide/api y {base_url}/guide/apps.\n\n" + skill + "\n\n" + read("api")
    )
