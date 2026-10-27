"""Verify live MCP session reporting without reading or changing meeting data."""
import fcntl
import json
import os
import select
import subprocess
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "dist/Meeting Recorder.app/Contents/MacOS/MeetingRecorderMCP"
DIRECTORY = Path(f"/private/tmp/meeting-recorder-mcp-{os.getuid()}")
TOKEN = "connection-test-" + uuid.uuid4().hex


def records():
    result = {}
    if DIRECTORY.exists():
        for path in DIRECTORY.glob("*.json"):
            try:
                record = json.loads(path.read_text())
                if record["name"].startswith(TOKEN):
                    result[record["name"]] = path
            except (OSError, ValueError, KeyError):
                continue
    return result


def send(process, payload, expect_reply=False):
    process.stdin.write(json.dumps(payload) + "\n")
    process.stdin.flush()
    if expect_reply:
        assert select.select([process.stdout], [], [], 5)[0], "server did not reply"
        reply = json.loads(process.stdout.readline())
        assert "result" in reply, reply


def start(name, diagnostic=False):
    process = subprocess.Popen([str(SERVER)] + (["--connection-check"] if diagnostic else []),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True, bufsize=1)
    send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": name, "version": "1"}}}, True)
    return process


def initialized(process):
    send(process, {"jsonrpc": "2.0", "method": "notifications/initialized"})
    send(process, {"jsonrpc": "2.0", "id": 2, "method": "ping"}, True)


def locked(path):
    with path.open("r+") as file:
        try:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        # Closing releases a lock acquired by this test, never the server's lock.
        return False


processes = []
try:
    first = start(TOKEN + "-one")
    processes.append(first)
    assert not records(), "initialize alone must not appear as a completed connection"
    initialized(first)
    first_path = records()[TOKEN + "-one"]
    assert locked(first_path), "live process must hold its presence lock"

    probe = start(TOKEN + "-diagnostic", diagnostic=True)
    processes.append(probe)
    initialized(probe)
    assert TOKEN + "-diagnostic" not in records(), "local self-check must not count as a client"
    probe.stdin.close()
    assert probe.wait(timeout=5) == 0

    second = start(TOKEN + "-two")
    processes.append(second)
    initialized(second)
    second_path = records()[TOKEN + "-two"]
    assert locked(second_path) and first_path != second_path, "concurrent clients need separate live records"
    first.stdin.close()
    assert first.wait(timeout=5) == 0
    assert not first_path.exists() and locked(second_path), "one disconnect must not hide another client"

    second.kill()
    second.wait(timeout=5)
    try:
        assert not locked(second_path), "a crashed process must not retain its lock"
        second_path.unlink(missing_ok=True)
    except FileNotFoundError:
        # A running app may already have swept the stale record.
        pass
    print("PASS: completed handshake, diagnostics excluded, concurrent clients, disconnect and crash locks")
finally:
    for process in processes:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    for path in records().values():
        path.unlink(missing_ok=True)
