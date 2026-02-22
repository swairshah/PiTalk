#!/usr/bin/env python3
"""
Inspect jump routing metadata by joining:
- pi telemetry instances (~/.pi/agent/telemetry/instances/*.json)
- statusd agents (~/.pi/agent/statusd.sock -> "status")
- tmux pane map (tty -> pane target)
- zellij layouts (session -> tab candidates)

Usage:
  python3 scripts/debug-jump-routing.py
  python3 scripts/debug-jump-routing.py --app FloatingChat
  python3 scripts/debug-jump-routing.py --pid 90586
  python3 scripts/debug-jump-routing.py --json
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

TELEMETRY_DIR = Path.home() / ".pi/agent/telemetry/instances"
STATUSD_SOCK = Path.home() / ".pi/agent/statusd.sock"


@dataclass
class TelemetryRow:
    pid: int
    ppid: int | None
    updated_at: int | None
    cwd: str | None
    session_id: str | None
    session_file: str | None
    alive: bool


@dataclass
class AgentRow:
    pid: int
    ppid: int | None
    tty: str | None
    cwd: str | None
    mux: str | None
    mux_session: str | None
    client_pid: int | None
    terminal_app: str | None


def is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def load_telemetry() -> dict[int, TelemetryRow]:
    rows: dict[int, TelemetryRow] = {}
    if not TELEMETRY_DIR.exists():
        return rows

    for path in glob.glob(str(TELEMETRY_DIR / "*.json")):
        try:
            with open(path, "r", encoding="utf-8") as f:
                obj = json.load(f)
        except Exception:
            continue

        proc = obj.get("process") or {}
        ws = obj.get("workspace") or {}
        sess = obj.get("session") or {}

        pid = proc.get("pid")
        if not isinstance(pid, int):
            continue

        row = TelemetryRow(
            pid=pid,
            ppid=proc.get("ppid") if isinstance(proc.get("ppid"), int) else None,
            updated_at=proc.get("updatedAt") if isinstance(proc.get("updatedAt"), int) else None,
            cwd=ws.get("cwd") if isinstance(ws.get("cwd"), str) else None,
            session_id=sess.get("id") if isinstance(sess.get("id"), str) else None,
            session_file=sess.get("file") if isinstance(sess.get("file"), str) else None,
            alive=is_pid_alive(pid),
        )
        rows[pid] = row

    return rows


def query_statusd() -> dict[int, AgentRow]:
    agents: dict[int, AgentRow] = {}

    if not STATUSD_SOCK.exists():
        return agents

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(1.0)
        sock.connect(str(STATUSD_SOCK))
        sock.sendall(b"status\n")

        chunks: list[bytes] = []
        while True:
            try:
                data = sock.recv(8192)
            except socket.timeout:
                break
            if not data:
                break
            chunks.append(data)
            if b"\n" in data:
                break
    except Exception:
        return agents
    finally:
        try:
            sock.close()
        except Exception:
            pass

    raw = b"".join(chunks).decode("utf-8", errors="replace").strip()
    if not raw:
        return agents

    # statusd usually returns one JSON object per line
    line = raw.splitlines()[0]
    try:
        obj = json.loads(line)
    except Exception:
        return agents

    for a in obj.get("agents") or []:
        try:
            pid = int(a.get("pid"))
        except Exception:
            continue

        agents[pid] = AgentRow(
            pid=pid,
            ppid=int(a["ppid"]) if isinstance(a.get("ppid"), (int, float)) else None,
            tty=a.get("tty") if isinstance(a.get("tty"), str) else None,
            cwd=a.get("cwd") if isinstance(a.get("cwd"), str) else None,
            mux=a.get("mux") if isinstance(a.get("mux"), str) else None,
            mux_session=a.get("mux_session") if isinstance(a.get("mux_session"), str) else None,
            client_pid=int(a["client_pid"]) if isinstance(a.get("client_pid"), (int, float)) else None,
            terminal_app=a.get("terminal_app") if isinstance(a.get("terminal_app"), str) else None,
        )

    return agents


def normalize_tty(tty: str | None) -> str | None:
    if not tty:
        return None
    if tty.startswith("/dev/"):
        return tty
    if tty == "??":
        return tty
    return f"/dev/{tty}"


def tmux_pane_map() -> dict[str, dict[str, str]]:
    m: dict[str, dict[str, str]] = {}
    try:
        proc = subprocess.run(
            [
                "tmux",
                "list-panes",
                "-a",
                "-F",
                "#{pane_tty} #{session_name}:#{window_index}.#{pane_index} #{window_name}",
            ],
            capture_output=True,
            text=True,
            timeout=1.5,
        )
    except Exception:
        return m

    if proc.returncode != 0:
        return m

    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" ", 2)
        if len(parts) < 2:
            continue
        tty = parts[0]
        target = parts[1]
        wname = parts[2] if len(parts) > 2 else ""
        m[tty] = {"target": target, "window": wname}
    return m


def parse_zellij_layout(layout: str) -> list[dict[str, Any]]:
    tabs: list[dict[str, Any]] = []
    tab_idx = 0
    current_name = ""

    for raw in layout.splitlines():
        line = raw.strip()
        if line.startswith("tab name="):
            tab_idx += 1
            name_match = re.search(r'name="([^"]+)"', line)
            current_name = name_match.group(1) if name_match else f"tab-{tab_idx}"
            continue

        if 'pane command="pi"' in line:
            cwd_match = re.search(r'cwd="([^"]+)"', line)
            pane_cwd = cwd_match.group(1) if cwd_match else ""
            tabs.append({
                "index": tab_idx,
                "name": current_name,
                "pane_cwd": pane_cwd,
            })

    return tabs


def zellij_pi_tabs(session: str) -> list[dict[str, Any]]:
    try:
        proc = subprocess.run(
            ["zellij", "-s", session, "action", "dump-layout"],
            capture_output=True,
            text=True,
            timeout=1.5,
        )
    except Exception:
        return []

    if proc.returncode != 0 or not proc.stdout:
        return []

    return parse_zellij_layout(proc.stdout)


def infer_app_label(cwd: str | None, session_file: str | None) -> str | None:
    def from_path(p: str | None) -> str | None:
        if not p:
            return None
        parts = Path(p).parts
        if "Application Support" in parts:
            i = parts.index("Application Support")
            if i + 1 < len(parts):
                return parts[i + 1]
        return None

    return from_path(cwd) or from_path(session_file)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int, help="show only one pid")
    ap.add_argument("--app", type=str, help="filter by app hint/cwd contains")
    ap.add_argument("--json", action="store_true", help="output JSON")
    args = ap.parse_args()

    telemetry = load_telemetry()
    agents = query_statusd()
    tmux_map = tmux_pane_map()

    zellij_sessions = sorted({a.mux_session for a in agents.values() if a.mux == "zellij" and a.mux_session})
    zellij_tabs_by_session = {s: zellij_pi_tabs(s) for s in zellij_sessions}

    pids = sorted(set(telemetry.keys()) | set(agents.keys()))
    out: list[dict[str, Any]] = []
    now_ms = int(time.time() * 1000)

    for pid in pids:
        t = telemetry.get(pid)
        a = agents.get(pid)

        cwd = (a.cwd if a and a.cwd else None) or (t.cwd if t else None)
        session_id = t.session_id if t else None
        session_file = t.session_file if t else None
        app_hint = infer_app_label(cwd, session_file)

        alive = t.alive if t else is_pid_alive(pid)
        age_ms = (now_ms - t.updated_at) if t and t.updated_at else None

        tty = normalize_tty(a.tty if a else None)
        mux = a.mux if a else None
        mux_session = a.mux_session if a else None

        jump_target: dict[str, Any] = {"type": "unknown"}

        if mux == "tmux" and tty and tty in tmux_map:
            jump_target = {
                "type": "tmux",
                "tty": tty,
                "target": tmux_map[tty]["target"],
                "window": tmux_map[tty]["window"],
            }
        elif mux == "zellij" and mux_session:
            tabs = zellij_tabs_by_session.get(mux_session, [])
            leaf = Path(cwd).name.lower() if cwd else None
            chosen = None
            if leaf:
                for tab in tabs:
                    pane_cwd = (tab.get("pane_cwd") or "").lower()
                    if pane_cwd == leaf or pane_cwd.endswith(leaf):
                        chosen = tab
                        break
            jump_target = {
                "type": "zellij",
                "session": mux_session,
                "tty": tty,
                "tab": chosen,
                "pi_tabs": tabs,
            }
        elif app_hint:
            jump_target = {"type": "app", "hint": app_hint}

        row = {
            "pid": pid,
            "alive": alive,
            "age_ms": age_ms,
            "session_id": session_id,
            "cwd": cwd,
            "app_hint": app_hint,
            "tty": a.tty if a else None,
            "mux": mux,
            "mux_session": mux_session,
            "client_pid": a.client_pid if a else None,
            "terminal_app": a.terminal_app if a else None,
            "jump_target": jump_target,
            "composite_key": {
                "session_id": session_id,
                "mux": mux,
                "mux_session": mux_session,
                "tty": a.tty if a else None,
            },
        }

        if args.pid and pid != args.pid:
            continue
        if args.app:
            needle = args.app.lower()
            hay = " ".join([
                str(row.get("cwd") or ""),
                str(row.get("app_hint") or ""),
            ]).lower()
            if needle not in hay:
                continue

        out.append(row)

    if args.json:
        print(json.dumps(out, indent=2))
        return 0

    # Human output
    print("pid     alive  mux      mux_session  tty      app_hint       session_id                              jump_target")
    print("-" * 130)
    for r in out:
        jt = r["jump_target"]
        if jt["type"] == "tmux":
            jt_s = f"tmux:{jt.get('target')}"
        elif jt["type"] == "zellij":
            tab = jt.get("tab")
            if tab:
                jt_s = f"zellij:{jt.get('session')}#tab{tab.get('index')}:{tab.get('name')}"
            else:
                jt_s = f"zellij:{jt.get('session')}#(no-tab-match)"
        elif jt["type"] == "app":
            jt_s = f"app:{jt.get('hint')}"
        else:
            jt_s = "unknown"

        sid = (r.get("session_id") or "-")[:36]
        print(
            f"{r['pid']:<7} "
            f"{str(r['alive']):<6} "
            f"{(r.get('mux') or '-'):<8} "
            f"{(r.get('mux_session') or '-'):<12} "
            f"{(r.get('tty') or '-'):<8} "
            f"{(r.get('app_hint') or '-'):<14} "
            f"{sid:<36} "
            f"{jt_s}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
