#!/usr/bin/env python3
"""
Claude Phone Hook — TUI Dashboard

Manage relay server and monitor hook activity.

Usage: ./tui.py
"""

import curses
import json
import os
import signal
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(SCRIPT_DIR, "notify.log")
RELAY_SCRIPT = os.path.join(SCRIPT_DIR, "relay.sh")
PID_FILE = os.path.join(SCRIPT_DIR, ".relay.pid")
RELAY_PORT = int(os.environ.get("RELAY_PORT", 9876))

# ── Helpers ───────────────────────────────────────────────────────────────────

def get_relay_pid():
    """Return relay PID if running, else None."""
    if not os.path.exists(PID_FILE):
        return None
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)  # check if alive
        return pid
    except (ValueError, ProcessLookupError, PermissionError):
        os.unlink(PID_FILE)
        return None


def start_relay():
    """Start the relay server in the background."""
    if get_relay_pid():
        return
    proc = subprocess.Popen(
        [sys.executable, RELAY_SCRIPT],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    with open(PID_FILE, "w") as f:
        f.write(str(proc.pid))


def stop_relay():
    """Stop the relay server."""
    pid = get_relay_pid()
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if os.path.exists(PID_FILE):
            os.unlink(PID_FILE)


def relay_health():
    """Check if relay is responding on its port."""
    try:
        import urllib.request
        resp = urllib.request.urlopen(
            f"http://localhost:{RELAY_PORT}/health", timeout=1
        )
        return resp.read().decode().strip() == "ok"
    except Exception:
        return False


def get_phone_hook_enabled():
    """Read PHONE_HOOK from Claude settings."""
    for path in [
        os.path.expanduser("~/.claude/settings.local.json"),
        os.path.expanduser("~/.claude/settings.json"),
    ]:
        try:
            with open(path) as f:
                data = json.load(f)
            val = data.get("env", {}).get("PHONE_HOOK")
            if val is not None:
                return val != "0", path
        except (FileNotFoundError, json.JSONDecodeError):
            continue
    return True, None  # default is enabled


def toggle_phone_hook():
    """Toggle PHONE_HOOK in the first settings file that has it."""
    enabled, path = get_phone_hook_enabled()
    if not path:
        path = os.path.expanduser("~/.claude/settings.json")
    try:
        with open(path) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        data = {}
    if "env" not in data:
        data["env"] = {}
    data["env"]["PHONE_HOOK"] = "0" if enabled else "1"
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def tail_log(n=8):
    """Return last n lines of notify.log."""
    if not os.path.exists(LOG_FILE):
        return ["(no log file yet)"]
    try:
        with open(LOG_FILE, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            # Read last ~4KB
            f.seek(max(0, size - 4096))
            lines = f.read().decode("utf-8", errors="replace").splitlines()
        return lines[-n:] if len(lines) > n else lines
    except Exception as e:
        return [f"(error reading log: {e})"]


def get_last_hook_info():
    """Parse the last hook invocation from the log."""
    lines = tail_log(50)
    last_invoked = None
    last_tool = None
    last_decision = None
    for line in lines:
        if "Hook invoked" in line:
            last_invoked = line.split("]")[0].lstrip("[").strip()
        if "Parsed: event=" in line:
            parts = line.split("tool=")
            if len(parts) > 1:
                last_tool = parts[1].split(" ")[0]
        if "Decision:" in line:
            last_decision = line.split("Decision:")[1].strip()
    return last_invoked, last_tool, last_decision


def get_tailscale_hostname():
    """Get the tailscale FQDN."""
    try:
        result = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True, text=True, timeout=3,
        )
        data = json.loads(result.stdout)
        return data.get("Self", {}).get("DNSName", "").rstrip(".")
    except Exception:
        return None


# ── TUI ──────────────────────────────────────────────────────────────────────

def draw(stdscr):
    curses.curs_set(0)
    stdscr.timeout(1000)  # refresh every 1s

    # Colors
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_GREEN, -1)   # on/healthy
    curses.init_pair(2, curses.COLOR_RED, -1)      # off/error
    curses.init_pair(3, curses.COLOR_YELLOW, -1)   # warning
    curses.init_pair(4, curses.COLOR_CYAN, -1)     # info
    curses.init_pair(5, curses.COLOR_MAGENTA, -1)  # accent
    curses.init_pair(6, curses.COLOR_WHITE, -1)    # dim

    GREEN = curses.color_pair(1) | curses.A_BOLD
    RED = curses.color_pair(2) | curses.A_BOLD
    YELLOW = curses.color_pair(3)
    CYAN = curses.color_pair(4)
    ACCENT = curses.color_pair(5) | curses.A_BOLD
    DIM = curses.color_pair(6)
    BOLD = curses.A_BOLD

    ts_host = get_tailscale_hostname()

    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()

        # ── Header ────────────────────────────────────────────────────
        title = " Claude Phone Hook "
        pad = (w - len(title)) // 2
        try:
            stdscr.addstr(0, 0, "─" * w, DIM)
            stdscr.addstr(0, max(0, pad), title, ACCENT)
            stdscr.addstr(1, 0, "─" * w, DIM)
        except curses.error:
            pass

        row = 3

        # ── Relay Status ──────────────────────────────────────────────
        relay_pid = get_relay_pid()
        healthy = relay_health() if relay_pid else False

        try:
            stdscr.addstr(row, 2, "RELAY SERVER", BOLD)
            row += 1

            if relay_pid and healthy:
                stdscr.addstr(row, 4, "● Running", GREEN)
                stdscr.addstr(row, 20, f"PID {relay_pid}  Port {RELAY_PORT}", DIM)
            elif relay_pid:
                stdscr.addstr(row, 4, "● PID exists but not responding", YELLOW)
            else:
                stdscr.addstr(row, 4, "● Stopped", RED)
            row += 1

            if ts_host:
                stdscr.addstr(row, 4, f"URL: http://{ts_host}:{RELAY_PORT}", CYAN)
            else:
                stdscr.addstr(row, 4, "Tailscale: not detected", YELLOW)
            row += 2

            # ── Hook Status ───────────────────────────────────────────
            stdscr.addstr(row, 2, "PHONE HOOK", BOLD)
            row += 1

            enabled, settings_path = get_phone_hook_enabled()
            if enabled:
                stdscr.addstr(row, 4, "● Enabled", GREEN)
            else:
                stdscr.addstr(row, 4, "● Disabled", RED)
            if settings_path:
                short = settings_path.replace(os.path.expanduser("~"), "~")
                stdscr.addstr(row, 20, f"({short})", DIM)
            row += 1

            last_invoked, last_tool, last_decision = get_last_hook_info()
            if last_invoked:
                stdscr.addstr(row, 4, f"Last: {last_invoked}", DIM)
                if last_tool:
                    stdscr.addstr(row, 4 + len(f"Last: {last_invoked}") + 2,
                                  f"Tool: {last_tool}", CYAN)
            else:
                stdscr.addstr(row, 4, "Last: no activity", DIM)
            row += 1
            if last_decision:
                color = GREEN if last_decision == "allow" else RED
                stdscr.addstr(row, 4, f"Decision: {last_decision}", color)
            row += 2

            # ── Log Tail ──────────────────────────────────────────────
            stdscr.addstr(row, 2, "RECENT LOG", BOLD)
            row += 1

            log_lines = tail_log(min(8, h - row - 4))
            for line in log_lines:
                if row >= h - 3:
                    break
                display = line[:w - 6]
                color = DIM
                if "Decision:" in line:
                    color = GREEN if "allow" in line else RED
                elif "brrr response" in line:
                    color = CYAN
                elif "Hook invoked" in line:
                    color = YELLOW
                stdscr.addstr(row, 4, display, color)
                row += 1

            # ── Controls ──────────────────────────────────────────────
            row = h - 2
            stdscr.addstr(row, 0, "─" * w, DIM)
            row = h - 1
            controls = [
                ("[r]", "elay start", GREEN if not relay_pid else DIM),
                ("[s]", "top relay", RED if relay_pid else DIM),
                ("[t]", "oggle hook", YELLOW),
                ("[l]", "og clear", DIM),
                ("[q]", "uit", DIM),
            ]
            col = 2
            for key, label, color in controls:
                stdscr.addstr(row, col, key, BOLD)
                stdscr.addstr(row, col + len(key), label, color)
                col += len(key) + len(label) + 3

        except curses.error:
            pass

        stdscr.refresh()

        # ── Input ─────────────────────────────────────────────────────
        try:
            key = stdscr.getch()
        except curses.error:
            key = -1

        if key == ord("q"):
            break
        elif key == ord("r"):
            start_relay()
            ts_host = get_tailscale_hostname()
        elif key == ord("s"):
            stop_relay()
        elif key == ord("t"):
            toggle_phone_hook()
        elif key == ord("l"):
            if os.path.exists(LOG_FILE):
                open(LOG_FILE, "w").close()


def main():
    try:
        curses.wrapper(draw)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
