"""TCP client for communicating with the BalatroBench Balatro mod."""

import json
import socket
import time


END_DELIMITER = "===END==="


class BalatroBenchClient:
    """Connects to the BalatroBench mod's TCP server inside Balatro."""

    def __init__(self, host: str = "127.0.0.1", port: int = 12345, timeout: float = 300):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock = None
        self.buffer = ""

    def connect(self, retries: int = 30, retry_delay: float = 2.0) -> bool:
        """Connect to the mod's TCP server. Retries until Balatro starts."""
        for attempt in range(retries):
            try:
                self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.sock.settimeout(10)
                self.sock.connect((self.host, self.port))
                self.sock.settimeout(self.timeout)
                print(f"[BalatroBench] Connected to mod at {self.host}:{self.port}")

                # Drain any greeting/initial data
                time.sleep(0.5)
                self.sock.settimeout(2)
                try:
                    chunk = self.sock.recv(4096).decode("utf-8")
                    self.buffer = chunk
                    print(f"[BalatroBench] Initial data: {chunk[:100]}...")
                except socket.timeout:
                    pass
                self.sock.settimeout(self.timeout)
                return True
            except (ConnectionRefusedError, socket.timeout, OSError) as e:
                if self.sock:
                    self.sock.close()
                    self.sock = None
                if attempt < retries - 1:
                    print(f"[BalatroBench] Waiting for Balatro... ({attempt + 1}/{retries})")
                    time.sleep(retry_delay)
        print("[BalatroBench] Failed to connect to mod")
        return False

    def disconnect(self):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def send_json(self, data: dict):
        """Send a JSON message."""
        if not self.sock:
            raise ConnectionError("Not connected")
        # ensure_ascii=False keeps non-ASCII (em-dashes, smart quotes, etc.)
        # as raw UTF-8 bytes instead of \uXXXX escapes, which the mod's
        # minimal Lua JSON decoder doesn't un-escape.
        msg = json.dumps(data, ensure_ascii=False) + "\n"
        self.sock.sendall(msg.encode("utf-8"))

    def recv_until_end(self) -> str:
        """Receive text until ===END=== delimiter or a JSON line."""
        lines = []
        while True:
            line = self._readline()
            if line is None:
                # Connection lost
                if lines:
                    return "\n".join(lines)
                return ""

            stripped = line.strip()

            # End delimiter
            if stripped == END_DELIMITER:
                return "\n".join(lines)

            # JSON message (action_result, error, run_complete, etc.)
            if stripped.startswith("{") and stripped.endswith("}"):
                try:
                    data = json.loads(stripped)
                    # If we already have accumulated text, this JSON is separate
                    if lines:
                        # Put it back in the buffer and return the text
                        self.buffer = stripped + "\n" + self.buffer
                        return "\n".join(lines)
                    # Otherwise return the JSON as-is
                    return stripped
                except json.JSONDecodeError:
                    pass

            lines.append(line)

    def recv_json(self) -> dict | None:
        """Receive a single JSON message."""
        # Check buffer first for any JSON we already have
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            line = line.strip()
            if line.startswith("{"):
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    continue

        # Read from socket
        line = self._readline()
        if line is None:
            return None
        line = line.strip()
        if not line:
            return None
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return None

    def _readline(self) -> str | None:
        """Read a single line from socket (blocking)."""
        if not self.sock:
            return None

        while "\n" not in self.buffer:
            try:
                chunk = self.sock.recv(4096).decode("utf-8")
                if not chunk:
                    return None
                self.buffer += chunk
            except socket.timeout:
                return None
            except (ConnectionResetError, BrokenPipeError, OSError):
                return None

        line, self.buffer = self.buffer.split("\n", 1)
        return line

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()
