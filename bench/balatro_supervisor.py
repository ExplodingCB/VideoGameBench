"""Supervisor for the Balatro.exe process.

Used by the webapp to guarantee a fresh, clean mod state between benchmark
runs. A common failure mode is that a model takes some action the mod can't
recover from (shop soft-lock on an unusual item, pack-open UI race, etc.).
When that happens subsequent runs start the mod loop but never get state back
and return "0 actions, ~104s timeout". The cure is always: kill Balatro, relaunch,
wait for TCP port 12345 to respond.

This module encapsulates that dance so the webapp can call
restart_balatro_and_wait_for_mod() between runs.
"""

from __future__ import annotations

import os
import socket
import subprocess
import time
from typing import Optional


# Default install path for Steam on Windows. Override with env var if needed.
DEFAULT_BALATRO_EXE = os.environ.get(
    "BALATRO_EXE",
    r"C:\Program Files (x86)\Steam\steamapps\common\Balatro\Balatro.exe",
)


def find_balatro_pids() -> list[int]:
    """Return PIDs of all running Balatro.exe processes."""
    try:
        # Using tasklist on Windows. /FI filter + /FO CSV for easy parsing.
        out = subprocess.check_output(
            ["tasklist", "/FI", "IMAGENAME eq Balatro.exe", "/FO", "CSV", "/NH"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return []
    pids: list[int] = []
    for line in out.splitlines():
        line = line.strip()
        if not line or "INFO:" in line:
            continue
        parts = [p.strip('"') for p in line.split('","')]
        # parts[1] is the PID column in tasklist CSV output
        if len(parts) >= 2:
            try:
                pids.append(int(parts[1]))
            except ValueError:
                pass
    return pids


def kill_balatro(pids: Optional[list[int]] = None, timeout: float = 8.0) -> bool:
    """Kill all running Balatro.exe processes. Returns True if none remain."""
    if pids is None:
        pids = find_balatro_pids()
    if not pids:
        return True
    # taskkill /F /PID <pid> for each. If multiple PIDs, one command with /PID repeated.
    cmd = ["taskkill", "/F"]
    for pid in pids:
        cmd += ["/PID", str(pid)]
    try:
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False
    # Poll for them to actually exit
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not find_balatro_pids():
            return True
        time.sleep(0.5)
    return False


def launch_balatro(exe_path: str = DEFAULT_BALATRO_EXE) -> Optional[int]:
    """Launch Balatro detached from the Python process. Returns the new PID."""
    if not os.path.exists(exe_path):
        return None
    # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP so Balatro outlives us
    # even if the webapp Python process exits.
    DETACHED_PROCESS = 0x00000008
    CREATE_NEW_PROCESS_GROUP = 0x00000200
    try:
        proc = subprocess.Popen(
            [exe_path],
            creationflags=DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
            close_fds=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return proc.pid
    except OSError:
        return None


def wait_for_mod(host: str = "127.0.0.1", port: int = 12345,
                 timeout: float = 60.0, poll_interval: float = 1.0) -> bool:
    """Block until we can connect to the mod's TCP server and read its
    'connected' handshake. Returns False on timeout.

    The mod takes 10-20 seconds to fully boot Balatro -> load Lovely ->
    inject Steamodded -> start the TCP listener. We probe with short-lived
    socket connections until one succeeds and the greeting arrives.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2.0)
        try:
            s.connect((host, port))
            # Read the greeting (server sends it immediately on accept)
            s.settimeout(3.0)
            data = b""
            try:
                chunk = s.recv(4096)
                if chunk:
                    data += chunk
            except socket.timeout:
                pass
            s.close()
            if b"connected" in data or b"BalatroBench" in data:
                return True
            # Port is open but no greeting — mod may not be ready yet.
        except (ConnectionRefusedError, socket.timeout, OSError):
            try:
                s.close()
            except OSError:
                pass
        time.sleep(poll_interval)
    return False


def restart_balatro_and_wait_for_mod(
    host: str = "127.0.0.1",
    port: int = 12345,
    exe_path: str = DEFAULT_BALATRO_EXE,
    boot_timeout: float = 90.0,
) -> tuple[bool, str]:
    """Kill any running Balatro, relaunch it, and wait for the mod TCP
    server to respond. Returns (success, message).
    """
    if not os.path.exists(exe_path):
        return False, f"Balatro.exe not found at {exe_path} (set BALATRO_EXE env var to override)"

    pids = find_balatro_pids()
    if pids:
        if not kill_balatro(pids):
            return False, f"Failed to kill Balatro (PIDs={pids})"

    pid = launch_balatro(exe_path)
    if pid is None:
        return False, "Failed to launch Balatro"

    ready = wait_for_mod(host=host, port=port, timeout=boot_timeout)
    if not ready:
        return False, f"Mod didn't respond within {boot_timeout}s after launching Balatro"

    return True, f"Balatro restarted (new PID {pid})"
