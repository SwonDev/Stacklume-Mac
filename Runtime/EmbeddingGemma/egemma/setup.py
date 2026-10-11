"""`egemma setup`: deja EmbeddingGemma 2 disponible en todos los asistentes detectados.

Para cada uno instala lo que entiende (skill, MCP, hook de inicio de sesión y regla). Además, el arranque
automático del servidor según el sistema, los atajos de la CLI y el modelo descargado. Es idempotente:
lo que ya está se deja como está, y antes de tocar un fichero de configuración se guarda una copia
`*.bak-egemma-<fecha>`.
"""

from __future__ import annotations

import json
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from .config import Config, home_dir

MCP_NAME = "embeddinggemma"
TASK_NAME = "EmbeddingGemma - servidor"
LAUNCHD_LABEL = "com.egemma.server"
SYSTEMD_UNIT = "egemma.service"
HOOK_STATUS = "Comprobando búsqueda semántica (EmbeddingGemma)..."

RULE_ROW = (
    "| buscar por significado (código sin saber su nombre, imágenes, audio, vídeo, PDF), duplicados, o "
    "embeddings/RAG/búsqueda semántica en una app | Semántica local | skill `embeddinggemma` (MCP `embeddinggemma`, API local "
    "`127.0.0.1:8737`) |"
)
RULE_SECTION = (
    "\n## Búsqueda semántica local (EmbeddingGemma 2)\n\n"
    "- Para buscar por significado (código sin saber su nombre, imágenes, audio, vídeo, PDF) o duplicados, usa "
    "el MCP `embeddinggemma` (`semantic_search` con la carpeta del proyecto) sin esperar a que te lo pidan.\n"
    "- Si el proyecto necesita embeddings, búsqueda semántica, RAG o recomendaciones, intégralo con la skill "
    "`embeddinggemma` o la herramienta `integration_guide` (API local compatible con OpenAI en "
    "`http://127.0.0.1:8737/v1`, modelo `embeddinggemma-2`).\n"
)


@dataclass
class Step:
    target: str
    what: str
    status: str  # hecho | ya estaba | actualizado | omitido | error
    detail: str = ""


# -- utilidades ------------------------------------------------------------------
def scripts_dir() -> Path:
    return Path(sys.executable).parent


def tool_path(name: str) -> Path:
    return scripts_dir() / (f"{name}.exe" if os.name == "nt" else name)


def posix(path: Path | str) -> str:
    return str(path).replace("\\", "/")


def backup(path: Path) -> None:
    if path.exists():
        target = path.with_name(f"{path.name}.bak-egemma-{time.strftime('%Y-%m-%d')}")
        if not target.exists():
            shutil.copy2(path, target)


def _run(args: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    exe = shutil.which(args[0]) or args[0]
    if sys.platform == "darwin" and args[0] in ("codex", "claude", "opencode"):
        for candidate in (Path.home() / ".local/bin" / args[0], Path.home() / "Library/pnpm/bin" / args[0]):
            if candidate.is_file() and os.access(candidate, os.X_OK):
                exe = str(candidate)
                break
    return subprocess.run(
        [exe, *args[1:]],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    backup(path)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _load_json(path: Path) -> dict:
    if not path.exists() or not path.read_text(encoding="utf-8").strip():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path} no contiene un objeto JSON")
    return data


def _jsonc_to_json(text: str) -> str:
    """Quita comentarios // y /* */ (fuera de cadenas) y comas finales, para validar un JSONC."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        else:
            out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


# -- piezas de configuración (puras sobre ficheros) -----------------------------------------
def install_skill(dest: Path, variant: str = "claude") -> str:
    """Copia la skill del paquete. `codex` cambia la herramienta Grep (que Codex no tiene) por rg."""
    from .guides import SKILL_DIR

    desired = {p.relative_to(SKILL_DIR): p.read_bytes() for p in SKILL_DIR.rglob("*") if p.is_file()}
    if variant == "codex":
        data = desired[Path("SKILL.md")].decode("utf-8")
        data = data.replace("sigue siendo mejor Grep o tgx.", "sigue siendo mejor rg o tgx.")
        data = data.replace("| Texto literal, nombre de función, regex | Grep / `tgx` |", "| Texto literal, nombre de función, regex | `rg` / `tgx` |")
        desired[Path("SKILL.md")] = data.encode("utf-8")
    existed = dest.exists()
    manifest = dest / ".egemma-instalada.json"
    previous = json.loads(manifest.read_text()) if manifest.exists() else {}
    hashes = {str(relative): hashlib.sha256(data).hexdigest() for relative, data in desired.items()}
    # Comprobar toda la instalación antes de escribir; un conflicto conserva la personalización.
    for relative, data in desired.items():
        path = dest / relative
        if path.exists() and path.read_bytes() != data:
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if previous.get(str(relative)) != actual:
                raise ValueError(f"Skill personalizada en {path}; se conserva sin sobrescribir")
    changed = False
    for relative, data in desired.items():
        path = dest / relative
        if path.exists() and path.read_bytes() == data:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        backup(path)
        path.write_bytes(data)
        changed = True
    if previous != hashes:
        manifest.write_text(json.dumps(hashes, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return "ya estaba" if not changed else ("actualizado" if existed else "hecho")


def _tree_text(root: Path) -> str | None:
    if not root.exists():
        return None
    return "\n".join(
        f"{p.relative_to(root).as_posix()}:{p.read_text(encoding='utf-8', errors='replace')}"
        for p in sorted(root.rglob("*"))
        if p.is_file()
    )


def add_rule(md: Path, create: bool = True) -> str:
    """Añade la regla a un fichero de reglas (CLAUDE.md, AGENTS.md, GEMINI.md).

    Si tiene una tabla de router (`| Trigger | … |`), añade una fila. Si no, añade una sección. Los
    ficheros generados por un script de reglas no se tocan: hay que regenerarlos.
    """
    if not md.exists():
        if not create:
            return "omitido"
        md.parent.mkdir(parents=True, exist_ok=True)
        md.write_text(RULE_SECTION.lstrip("\n"), encoding="utf-8")
        return "hecho"
    text = md.read_text(encoding="utf-8")
    if MCP_NAME in text:
        return "ya estaba"
    if "generado por reglas-espejos" in text or "generado por reglas-harness" in text or ("Generado" in text[:400] and "No lo edites" in text[:400]):
        return "generado"
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.lstrip().startswith("| Trigger") and i + 1 < len(lines) and set(lines[i + 1].strip()) <= set("|-: "):
            j = i + 2
            while j < len(lines) and lines[j].lstrip().startswith("|"):
                j += 1
            lines.insert(j, RULE_ROW + "\n")
            backup(md)
            md.write_text("".join(lines), encoding="utf-8")
            return "hecho"
    backup(md)
    md.write_text(text.rstrip("\n") + "\n" + RULE_SECTION, encoding="utf-8")
    return "hecho"


def _is_our_hook(hook: dict) -> bool:
    blob = json.dumps(hook)
    return "egemma" in blob and "session-start" in blob


def add_claude_hook(settings: Path, egemma: Path) -> str:
    """Hook SessionStart de Claude Code (lo ejecutan también OMP y cualquier harness que lea settings.json).

    Se usa la forma de orden en una línea, que admiten todas las versiones de Claude Code.
    """
    data = _load_json(settings)
    groups = data.setdefault("hooks", {}).setdefault("SessionStart", [])
    expected = {
        "type": "command",
        "command": f'"{posix(egemma)}" hook session-start --format claude',
        "timeout": 10,
        "statusMessage": HOOK_STATUS,
    }
    for group in groups:
        hooks = group.get("hooks", [])
        for i, hook in enumerate(hooks):
            if _is_our_hook(hook):
                if hook == expected:
                    return "ya estaba"
                hooks[i] = expected
                _write_json(settings, data)
                return "actualizado"
    groups.append({"hooks": [expected]})
    _write_json(settings, data)
    return "hecho"


def add_codex_hook(hooks_file: Path, egemma: Path) -> str:
    data = _load_json(hooks_file)
    groups = data.setdefault("hooks", {}).setdefault("SessionStart", [])
    command = f'"{posix(egemma)}" hook session-start --format text'
    for group in groups:
        for hook in group.get("hooks", []):
            if _is_our_hook(hook):
                if hook.get("command") == command:
                    return "ya estaba"
                hook["command"] = command
                hook["commandWindows"] = command
                _write_json(hooks_file, data)
                return "actualizado"
    groups.append(
        {
            "hooks": [
                {
                    "type": "command",
                    "command": command,
                    "commandWindows": command,
                    "timeout": 10,
                    "statusMessage": HOOK_STATUS,
                }
            ]
        }
    )
    _write_json(hooks_file, data)
    return "hecho"


def add_mcp_servers_json(path: Path, command: str) -> str:
    """Formato `mcpServers` (Gemini CLI, Cursor, Claude Desktop, Antigravity)."""
    data = _load_json(path)
    servers = data.setdefault("mcpServers", {})
    current = servers.get(MCP_NAME)
    if isinstance(current, dict) and current.get("command") == command:
        return "ya estaba"
    servers[MCP_NAME] = {"command": command, "args": []}
    _write_json(path, data)
    return "actualizado" if current else "hecho"


def add_opencode_mcp(path: Path, command: str) -> str:
    """Añade la entrada `mcp.embeddinggemma` a la configuración de OpenCode (JSON o JSONC) sin perder comentarios."""
    entry = json.dumps({"type": "local", "command": [command], "enabled": True, "timeout": 600000})
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        data = {"$schema": "https://opencode.ai/config.json", "mcp": {MCP_NAME: json.loads(entry)}}
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return "hecho"
    text = path.read_text(encoding="utf-8")
    if f'"{MCP_NAME}"' in text:
        return "ya estaba"
    line = f'\n    "{MCP_NAME}": {entry}'
    match = re.search(r'"mcp"\s*:\s*\{', text)
    if match:
        rest = text[match.end():]
        sep = "" if rest.lstrip().startswith("}") else ","
        new = text[: match.end()] + line + sep + rest
    else:
        idx = text.rstrip().rfind("}")
        before = text[:idx].rstrip()
        comma = "" if before.endswith(("{", ",")) else ","
        new = before + comma + f'\n  "mcp": {{{line}\n  }}\n' + text[idx:]
    json.loads(_jsonc_to_json(new))  # si no es válido, lanza y no se escribe nada
    backup(path)
    path.write_text(new, encoding="utf-8")
    return "hecho"


def launchd_plist(egemma: Path) -> bytes:
    logs = home_dir() / "logs"
    return plistlib.dumps(
        {
            "Label": LAUNCHD_LABEL,
            "ProgramArguments": [str(egemma), "serve", "--log-to-file"],
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ThrottleInterval": 30,
            "WorkingDirectory": str(home_dir()),
            "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
            "StandardOutPath": str(logs / "launchd.out.log"),
            "StandardErrorPath": str(logs / "launchd.err.log"),
        }
    )


def systemd_unit(egemma: Path) -> str:
    return (
        "[Unit]\nDescription=EmbeddingGemma 2 local (egemma)\nAfter=default.target\n\n"
        f"[Service]\nExecStart={egemma} serve --log-to-file\nRestart=on-failure\nRestartSec=30\n"
        f"WorkingDirectory={home_dir()}\n\n[Install]\nWantedBy=default.target\n"
    )


# -- arranque automático -----------------------------------------------------------------
def _ps(script: str) -> subprocess.CompletedProcess:
    return _run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", "[Console]::OutputEncoding = [Text.Encoding]::UTF8; " + script]
    )


def _ps_quote(value: object) -> str:
    return str(value).replace("'", "''")


def autostart(action: str) -> tuple[bool, str]:
    """install | uninstall | status, según el sistema."""
    server = tool_path("egemma-server") if os.name == "nt" else tool_path("egemma")
    if sys.platform == "win32":
        if action == "install":
            if not server.exists():
                return False, f"no encuentro {server}; ejecuta `uv sync` en {home_dir()}"
            current = _ps(
                f"$t = Get-ScheduledTask -TaskName '{TASK_NAME}' -ErrorAction SilentlyContinue; if ($t) {{ $t.Actions[0].Execute }}"
            ).stdout.strip()
            if current and Path(current) == server:
                return True, "ya estaba"
            script = f"""
$ErrorActionPreference = 'Stop'
$user = "$env:USERDOMAIN\\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute '{_ps_quote(server)}' -WorkingDirectory '{_ps_quote(home_dir())}'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName '{TASK_NAME}' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Servicio local de EmbeddingGemma 2 (API en http://127.0.0.1:8737). El modelo se carga bajo demanda.' -Force | Out-Null
Start-ScheduledTask -TaskName '{TASK_NAME}'
'hecho'
"""
        elif action == "uninstall":
            script = f"Unregister-ScheduledTask -TaskName '{TASK_NAME}' -Confirm:$false; 'hecho'"
        else:
            script = (
                f"$t = Get-ScheduledTask -TaskName '{TASK_NAME}' -ErrorAction SilentlyContinue; "
                "if ($t) { $i = $t | Get-ScheduledTaskInfo; \"$($t.State) · última ejecución $($i.LastRunTime) · resultado $($i.LastTaskResult)\" } else { 'no instalada' }"
            )
        result = _ps(script)
        return result.returncode == 0, (result.stdout or result.stderr).strip()

    if sys.platform == "darwin":
        plist_path = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCHD_LABEL}.plist"
        domain = f"gui/{os.getuid()}"
        if action == "install":
            content = launchd_plist(server)
            (home_dir() / "logs").mkdir(parents=True, exist_ok=True)
            loaded = _run(["launchctl", "print", f"{domain}/{LAUNCHD_LABEL}"]).returncode == 0
            if plist_path.exists() and plist_path.read_bytes() == content and loaded:
                return True, "ya estaba"
            plist_path.parent.mkdir(parents=True, exist_ok=True)
            plist_path.write_bytes(content)
            _run(["launchctl", "bootout", f"{domain}/{LAUNCHD_LABEL}"])
            for _ in range(5):  # tras bootout, launchd tarda un momento en soltar el servicio (error 5)
                result = _run(["launchctl", "bootstrap", domain, str(plist_path)])
                if result.returncode == 0:
                    return True, "hecho"
                time.sleep(2)
            return False, (result.stderr or result.stdout).strip()
        if action == "uninstall":
            _run(["launchctl", "bootout", f"{domain}/{LAUNCHD_LABEL}"])
            plist_path.unlink(missing_ok=True)
            return True, "hecho"
        result = _run(["launchctl", "print", f"{domain}/{LAUNCHD_LABEL}"])
        if result.returncode != 0:
            return False, "no instalado"
        state = re.search(r"state = (\w+)", result.stdout)
        return True, f"LaunchAgent {LAUNCHD_LABEL}: {state.group(1) if state else 'cargado'}"

    unit_path = Path.home() / ".config" / "systemd" / "user" / SYSTEMD_UNIT
    if action == "install":
        content = systemd_unit(server)
        if unit_path.exists() and unit_path.read_text(encoding="utf-8") == content:
            _run(["systemctl", "--user", "enable", "--now", SYSTEMD_UNIT])
            return True, "ya estaba"
        unit_path.parent.mkdir(parents=True, exist_ok=True)
        unit_path.write_text(content, encoding="utf-8")
        _run(["systemctl", "--user", "daemon-reload"])
        result = _run(["systemctl", "--user", "enable", "--now", SYSTEMD_UNIT])
        return result.returncode == 0, (result.stderr or "hecho").strip()
    if action == "uninstall":
        _run(["systemctl", "--user", "disable", "--now", SYSTEMD_UNIT])
        unit_path.unlink(missing_ok=True)
        return True, "hecho"
    result = _run(["systemctl", "--user", "is-active", SYSTEMD_UNIT])
    return result.returncode == 0, result.stdout.strip() or "no instalado"


def _autostart_step() -> tuple[str, str]:
    ok, message = autostart("install")
    if not ok:
        raise RuntimeError(message)
    return ("ya estaba" if message == "ya estaba" else "hecho"), ("" if message in ("ya estaba", "hecho") else message)


# -- atajos de la CLI ----------------------------------------------------------------
def install_shims() -> tuple[str, str]:
    bin_dir = Path.home() / ".local" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    egemma = tool_path("egemma")
    in_path = any(Path(p).resolve() == bin_dir.resolve() for p in os.environ.get("PATH", "").split(os.pathsep) if p)
    note = "" if in_path else f"añade {bin_dir} al PATH"
    if os.name == "nt":
        cmd = f'@echo off\r\nsetlocal\r\n"{egemma}" %*\r\nexit /b %errorlevel%\r\n'
        sh = f'#!/usr/bin/env bash\n# Envoltorio de egemma (EmbeddingGemma 2 local) para shells POSIX (Git Bash, WSL).\nexec "{posix(egemma)}" "$@"\n'
        changed = False
        for path, content in ((bin_dir / "egemma.cmd", cmd), (bin_dir / "egemma", sh)):
            if not path.exists() or path.read_bytes() != content.encode("utf-8"):
                path.write_text(content, encoding="utf-8", newline="")
                changed = True
        return ("hecho" if changed else "ya estaba"), note
    link = bin_dir / "egemma"
    if link.is_symlink() and Path(os.readlink(link)) == egemma:
        return "ya estaba", note
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(egemma)
    return "hecho", note


# -- asistentes ------------------------------------------------------------------------
def _claude_mcp(command: str) -> str:
    got = _run(["claude", "mcp", "get", MCP_NAME])
    if got.returncode == 0:
        if command in got.stdout.replace("\\", "/"):
            return "ya estaba"
        _run(["claude", "mcp", "remove", "-s", "user", MCP_NAME])
    added = _run(["claude", "mcp", "add", "-s", "user", MCP_NAME, "--", command])
    if added.returncode != 0:
        raise RuntimeError(added.stderr.strip() or added.stdout.strip())
    return "hecho"


def _codex_mcp(command: str) -> str:
    got = _run(["codex", "mcp", "get", MCP_NAME])
    if got.returncode == 0:
        if command in got.stdout.replace("\\", "/"):
            return "ya estaba"
        _run(["codex", "mcp", "remove", MCP_NAME])
    backup(Path.home() / ".codex" / "config.toml")
    added = _run(["codex", "mcp", "add", MCP_NAME, "--", command])
    if added.returncode != 0:
        raise RuntimeError(added.stderr.strip() or added.stdout.strip())
    return "hecho"


def _claude_desktop_config() -> Path | None:
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / "Claude"
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support" / "Claude"
    else:
        base = Path.home() / ".config" / "Claude"
    return base / "claude_desktop_config.json" if base.exists() else None


def _rules_generator() -> Path | None:
    gen = Path.home() / ".config" / "metodologia-ia" / "reglas" / "generar_reglas.py"
    if gen.exists():
        return gen
    gen = Path.home() / ".local" / "bin" / "reglas-espejos"
    return gen if gen.exists() else None


def detect() -> dict[str, bool]:
    home = Path.home()
    return {
        "claude": bool(shutil.which("claude")) or (home / ".claude").exists(),
        "codex": bool(shutil.which("codex")) or (home / ".codex").exists(),
        "opencode": bool(shutil.which("opencode")) or (home / ".config" / "opencode").exists(),
        "gemini": bool(shutil.which("gemini")),
        "omp": bool(shutil.which("omp")) or (home / ".omp").exists(),
        "cursor": (home / ".cursor").exists(),
        "antigravity": (home / ".gemini" / "antigravity" / "mcp_config.json").exists(),
        "claude-desktop": _claude_desktop_config() is not None,
    }


def _step(steps: list[Step], target: str, what: str, fn, *args) -> str | None:
    try:
        result = fn(*args)
        status, detail = result if isinstance(result, tuple) else (result, "")
        steps.append(Step(target, what, status, detail))
        return status
    except Exception as exc:  # noqa: BLE001 — un asistente roto no frena a los demás
        steps.append(Step(target, what, "error", f"{type(exc).__name__}: {exc}"))
        return None


def configure_harnesses(only: set[str] | None = None) -> list[Step]:
    steps: list[Step] = []
    home = Path.home()
    mcp_cmd = posix(tool_path("egemma-mcp"))
    egemma = tool_path("egemma")
    found = detect()

    def wanted(name: str) -> bool:
        if only and name not in only:
            return False
        if not found.get(name):
            steps.append(Step(name, "detección", "omitido", "no instalado"))
            return False
        return True

    rules_changed = False
    if wanted("claude"):
        _step(steps, "claude", "skill", install_skill, home / ".claude" / "skills" / "embeddinggemma")
        _step(steps, "claude", "MCP (usuario)", _claude_mcp, mcp_cmd)
        _step(steps, "claude", "hook SessionStart", add_claude_hook, home / ".claude" / "settings.json", egemma)
        rules_changed = _step(steps, "claude", "regla en CLAUDE.md", add_rule, home / ".claude" / "CLAUDE.md") == "hecho"
    if wanted("codex"):
        _step(steps, "codex", "skill", install_skill, home / ".codex" / "skills" / "embeddinggemma", "codex")
        _step(steps, "codex", "MCP", _codex_mcp, mcp_cmd)
        _step(steps, "codex", "hook SessionStart", add_codex_hook, home / ".codex" / "hooks.json", egemma)
        _step(steps, "codex", "regla en AGENTS.md", add_rule, home / ".codex" / "AGENTS.md")
    if wanted("opencode"):
        cfg_dir = home / ".config" / "opencode"
        target = cfg_dir / "opencode.jsonc" if (cfg_dir / "opencode.jsonc").exists() else cfg_dir / "opencode.json"
        steps.append(Step("opencode", "skill", "ya estaba", "lee ~/.claude/skills y ~/.agents/skills"))
        _step(steps, "opencode", f"MCP ({target.name})", add_opencode_mcp, target, mcp_cmd)
        _step(steps, "opencode", "regla en AGENTS.md", add_rule, cfg_dir / "AGENTS.md")
    if wanted("gemini"):
        _step(steps, "gemini", "skill", install_skill, home / ".gemini" / "skills" / "embeddinggemma")
        _step(steps, "gemini", "MCP (settings.json)", add_mcp_servers_json, home / ".gemini" / "settings.json", mcp_cmd)
        _step(steps, "gemini", "regla en GEMINI.md", add_rule, home / ".gemini" / "GEMINI.md")
    if wanted("omp"):
        steps.append(Step("omp", "configuración", "ya estaba", "se verifica su configuración MCP nativa"))
    if wanted("cursor"):
        _step(steps, "cursor", "MCP (~/.cursor/mcp.json)", add_mcp_servers_json, home / ".cursor" / "mcp.json", mcp_cmd)
    if wanted("antigravity"):
        _step(
            steps, "antigravity", "MCP", add_mcp_servers_json, home / ".gemini" / "antigravity" / "mcp_config.json", mcp_cmd
        )
    if wanted("claude-desktop"):
        desktop = _claude_desktop_config()
        assert desktop is not None
        _step(steps, "claude-desktop", "MCP (reinicia la app)", add_mcp_servers_json, desktop, mcp_cmd)

    generator = _rules_generator()
    if generator and (rules_changed or any(s.status == "generado" for s in steps)):
        result = _run([sys.executable, str(generator)] + ([] if generator.name == "reglas-espejos" else ["--si-cambia"]), timeout=300)
        steps.append(
            Step("reglas", "regenerar AGENTS.md (generar_reglas.py)", "hecho" if result.returncode == 0 else "error", result.stdout.strip()[-300:])
        )
    if sys.platform == "darwin":
        from .mac_setup import configure_extra
        steps.extend(configure_extra(only))
    return steps


def download_model(cfg: Config) -> str:
    from huggingface_hub import snapshot_download

    try:
        snapshot_download(cfg.mlx_model if cfg.backend == "mlx" else cfg.model, revision=cfg.mlx_revision if cfg.backend == "mlx" else None, local_files_only=True)
        return "ya estaba"
    except Exception:  # noqa: BLE001 — no está en caché
        snapshot_download(cfg.mlx_model if cfg.backend == "mlx" else cfg.model, revision=cfg.mlx_revision if cfg.backend == "mlx" else None)
        return "hecho"


def verify(cfg: Config) -> tuple[str, str]:
    from .client import Client

    with Client(cfg) as client:
        client.ensure_running(timeout=60)
        started = time.time()
        res = client.post("/embed", {"inputs": ["prueba de instalación"], "dimensions": 768})
        info = client.health() or {}
    worker = (info.get("engine") or {}).get("worker") or {}
    if res.get("dimensions") != 768:
        raise RuntimeError(f"respuesta inesperada: {res}")
    return "hecho", f"{worker.get('device')} {worker.get('dtype')} · {worker.get('gpu') or ''} · {time.time() - started:.1f} s"


def run_setup(cfg: Config, only: set[str] | None = None, with_autostart: bool = True, with_model: bool = True, with_verify: bool = True) -> list[Step]:
    steps: list[Step] = []
    if with_model:
        _step(steps, "servicio", "modelo descargado", download_model, cfg)
    if with_autostart:
        from .client import Client

        with Client(cfg) as client:
            if client.health() is not None and autostart("status")[1] in ("no instalada", "no instalado"):
                client.http.post("/shutdown")  # que lo arranque el sistema, no una instancia suelta
                time.sleep(3)
        _step(steps, "servicio", "arranque automático", _autostart_step)
    _step(steps, "servicio", "atajo `egemma` en ~/.local/bin", install_shims)
    steps.extend(configure_harnesses(only))
    if with_verify:
        _step(steps, "servicio", "prueba real (embedding)", verify, cfg)
    return steps
