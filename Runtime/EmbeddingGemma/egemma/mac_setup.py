"""Configuración adicional para los harnesses y los perfiles de skills de este Mac."""
from __future__ import annotations

from pathlib import Path
import yaml
from .setup import (MCP_NAME, Step, _run, _step, add_mcp_servers_json,
                    backup, install_skill, posix, tool_path)


def link_skill(path: Path, source: Path) -> str:
    if path.is_symlink() and path.resolve() == source.resolve():
        return "ya estaba"
    if path.exists() or path.is_symlink():
        raise ValueError(f"Ya existe otra skill en {path}; se conserva")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to(source, target_is_directory=True)
    return "hecho"


def add_hermes(path: Path, command: str) -> str:
    text = path.read_text(encoding="utf-8")
    data = yaml.safe_load(text)
    current = data.get("mcp_servers", {}).get(MCP_NAME)
    expected = {"command": command, "args": [], "enabled": True}
    if current == expected:
        return "ya estaba"
    if current:
        raise ValueError("Existe otra configuración de embeddinggemma; se conserva")
    lines = text.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.startswith("mcp_servers:")), None)
    entry = yaml.safe_dump({MCP_NAME: expected}, allow_unicode=True, sort_keys=False)
    entry = "".join("  " + line for line in entry.splitlines(keepends=True))
    if start is None:
        new = text.rstrip() + "\nmcp_servers:\n" + entry
    else:
        end = next((i for i in range(start + 1, len(lines)) if lines[i].strip() and
                    not lines[i][0].isspace() and not lines[i].startswith("#")), len(lines))
        lines.insert(end, entry)
        new = "".join(lines)
    yaml.safe_load(new)
    backup(path)
    path.write_text(new, encoding="utf-8")
    return "hecho"


def add_dsh(path: Path, command: str) -> str:
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    class PatchLoader(yaml.SafeLoader):
        pass
    PatchLoader.add_constructor("tag:yaml.org,2002:js", lambda loader, node: loader.construct_scalar(node))
    data = yaml.load(text, Loader=PatchLoader) or []
    expected = {"id": "mcp-embeddinggemma", "name": "@deepseek-ai/dsh-mcp-client", "config": {
        "serverName": MCP_NAME, "transport": "stdio", "command": command, "args": [],
        "toolCallTimeoutMs": 600000, "failOnStartupError": False}}
    for patch in data:
        for entry in patch.get("insert", []):
            if entry.get("id") == expected["id"]:
                if entry == expected:
                    return "ya estaba"
                raise ValueError("Existe otra configuración de embeddinggemma; se conserva")
    new = text.rstrip() + "\n" + yaml.safe_dump([{"insert": [expected]}], allow_unicode=True, sort_keys=False)
    yaml.load(new, Loader=PatchLoader)
    backup(path)
    path.write_text(new, encoding="utf-8")
    return "hecho"


def add_pool(home: Path) -> tuple[str, str]:
    pool = home / ".codex/skills-pool/embeddinggemma"
    skill_result = install_skill(pool, "codex")
    core = home / ".codex/perfiles/nucleo.txt"
    changed = skill_result in ("hecho", "actualizado")
    if core.exists() and MCP_NAME not in core.read_text().splitlines():
        backup(core)
        core.write_text(core.read_text().rstrip() + "\n\n# Búsqueda semántica disponible en todos los proyectos.\nembeddinggemma\n", encoding="utf-8")
        changed = True
    active = home / ".codex/skills/embeddinggemma"
    if not active.exists() and not active.is_symlink():
        link_skill(active, pool)
        changed = True
    return ("hecho" if changed else "ya estaba"), "incluida en el núcleo de todos los perfiles"


def configure_extra(only: set[str] | None = None) -> list[Step]:
    home = Path.home()
    steps: list[Step] = []
    command = posix(tool_path("egemma-mcp"))
    source = home / ".claude/skills/embeddinggemma"
    targets = {
        "qwen": (home / ".qwen", "settings.json", "skills"),
        "kimi": (home / ".kimi-code", "mcp.json", "skills"),
        "mcode": (home / ".minimax", "mcp.json", "skills"),
        "omp": (home / ".omp/agent", "mcp.json", "skills"),
    }
    for name, (base, config, skills) in targets.items():
        if (only and name not in only) or not base.exists():
            continue
        _step(steps, name, "MCP", add_mcp_servers_json, base / config, command)
        _step(steps, name, "skill", link_skill, base / skills / MCP_NAME, source)
    for name, base in (("dsh", home / ".dsh"), ("gentle-shell", home / ".gentle-shell/agent")):
        if (only and name not in only) or not base.exists():
            continue
        _step(steps, name, "skill", link_skill, base / "skills" / MCP_NAME, source)
        if name == "dsh":
            _step(steps, name, "MCP (todos los perfiles)", add_dsh, base / "cordis.patch.yml", command)
        else:
            steps.append(Step(name, "CLI compartida", "ya estaba", "egemma en PATH; Pi no hereda el MCP de Claude"))
    if (not only or "hermes" in only) and (home / ".hermes").exists():
        for config in [home / ".hermes/config.yaml", home / ".hermes/profiles/programar/config.yaml"]:
            if config.exists():
                _step(steps, "hermes", f"MCP ({config.parent.name})", add_hermes, config, command)
        _step(steps, "hermes", "skill (programación)", link_skill,
              home / ".local/share/programar/skills/embeddinggemma", source)
    if (not only or "codex" in only) and (home / ".codex").exists():
        _step(steps, "codex", "skill en todos los perfiles", add_pool, home)
    if (not only or "opencode" in only) and (home / ".config/opencode").exists():
        _step(steps, "opencode", "skill compartida", link_skill,
              home / ".config/opencode/skills/embeddinggemma", source)
    generator = home / ".local/bin/reglas-harness"
    if generator.exists() and not only:
        for name in ("omp", "gentle-shell", "hermes-programar"):
            def generate(name=name):
                targets = {"omp": home / ".omp/agent/AGENTS.md", "gentle-shell": home / ".gentle-shell/agent/AGENTS.md", "hermes-programar": home / ".hermes/profiles/programar/SOUL.md"}
                target = targets[name]
                before = target.read_bytes() if target.exists() else None
                result = _run([str(generator), name])
                if result.returncode:
                    raise RuntimeError(result.stderr.strip())
                return "ya estaba" if target.exists() and target.read_bytes() == before else "hecho"
            _step(steps, "reglas", f"espejo {name}", generate)
    return steps
