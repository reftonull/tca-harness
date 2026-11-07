"""`harness.toml` targets: how to launch a fresh app process for a run, and how to stop it.

```toml
[targets.headless]
launch = ".build/debug/shelf-headless --port {port}"
port = "auto"                       # or a fixed port
ready = "TCA harness listening"     # stderr/stdout line meaning ready; otherwise poll the port
ready_timeout = 30                  # seconds
restart = "per-run"                 # per-run | never
env = { SHELF_API = "http://127.0.0.1:8799" }
stop = "flowdeck stop"              # optional; run after the process group is signalled
```
"""
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import threading
import time
import tomllib

CONFIG_NAME = 'harness.toml'
RESTARTS = ('per-run', 'never')


class TargetError(RuntimeError):
    """harness.toml is missing or invalid, or a target could not be launched."""


@dataclass
class Target:
    name: str
    launch: str
    root: Path
    port: object = 'auto'
    ready: str | None = None
    ready_timeout: float = 30.0
    restart: str = 'per-run'
    env: dict = field(default_factory=dict)
    stop: str | None = None


def find_config(*starts):
    """The nearest harness.toml at or above any start path (files start at their directory)."""
    for start in starts:
        if start is None:
            continue
        directory = Path(start).resolve()
        if directory.is_file() or not directory.exists():
            directory = directory.parent
        for candidate in (directory, *directory.parents):
            path = candidate / CONFIG_NAME
            if path.is_file():
                return path
    return None


def load_targets(path):
    path = Path(path)
    try:
        data = tomllib.loads(path.read_text())
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise TargetError(f'{path}: {error}') from None
    tables = data.get('targets')
    if not isinstance(tables, dict) or not tables:
        raise TargetError(f'{path}: no [targets.NAME] tables')
    targets = {}
    for name, table in tables.items():
        where = f'{path}: targets.{name}'
        if not isinstance(table, dict) or not isinstance(table.get('launch'), str) or not table['launch'].strip():
            raise TargetError(f'{where}: `launch` must be a command string')
        port = table.get('port', 'auto')
        if port != 'auto' and not (isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535):
            raise TargetError(f'{where}: `port` must be "auto" or a port number')
        restart = table.get('restart', 'per-run')
        if restart not in RESTARTS:
            raise TargetError(f'{where}: `restart` must be per-run or never')
        env = table.get('env', {})
        if not isinstance(env, dict) or not all(isinstance(v, (str, int, float, bool)) for v in env.values()):
            raise TargetError(f'{where}: `env` must be a table of strings')
        timeout = table.get('ready_timeout', 30)
        if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or timeout <= 0:
            raise TargetError(f'{where}: `ready_timeout` must be a positive number of seconds')
        for text in ('ready', 'stop'):
            if table.get(text) is not None and not isinstance(table[text], str):
                raise TargetError(f'{where}: `{text}` must be a string')
        targets[name] = Target(name=name, launch=table['launch'], root=path.parent, port=port,
                               ready=table.get('ready'), ready_timeout=float(timeout), restart=restart,
                               env={k: str(v) for k, v in env.items()}, stop=table.get('stop'))
    return targets


def resolve_target(name, *starts):
    """(Target, config path) for `name`; without a name, `headless` or else the only target."""
    path = find_config(*starts)
    if path is None:
        searched = ', '.join(str(Path(s).resolve()) for s in starts if s is not None)
        raise TargetError(f'No {CONFIG_NAME} found at or above {searched}; add one (see docs/testing.md#targets) '
                          'or pass --port to use an app that is already running')
    targets = load_targets(path)
    if name is None:
        name = 'headless' if 'headless' in targets else next(iter(targets)) if len(targets) == 1 else None
        if name is None:
            raise TargetError(f'{path}: several targets; choose one with --target ({", ".join(targets)})')
    if name not in targets:
        raise TargetError(f'{path}: no target {name!r}; have {", ".join(targets)}')
    return targets[name], path


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def port_open(port, timeout=0.2):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=timeout):
            return True
    except OSError:
        return False


def run_environment(network=None, cassettes=None, seed=None, port=None, faults=None, latency=None):
    """The TCA_HARNESS_* settings for one run, in a stable order. `faults` (launch faults) become
    TCA_HARNESS_FAULTS, compact JSON the app applies from its first request; `latency` (replay
    latency, a dict) becomes TCA_HARNESS_LATENCY."""
    values = {}
    if network:
        values['TCA_HARNESS_NETWORK'] = network
    if cassettes:
        values['TCA_HARNESS_CASSETTES'] = str(Path(cassettes).resolve())
    if seed is not None:
        values['TCA_HARNESS_SEED'] = str(int(seed))
    if port is not None:
        values['TCA_HARNESS_PORT'] = str(port)
    if faults:
        values['TCA_HARNESS_FAULTS'] = json.dumps(faults, separators=(',', ':'))
    if latency:
        values['TCA_HARNESS_LATENCY'] = json.dumps(latency, separators=(',', ':'), sort_keys=True)
    return values


def expand(command, port, variables):
    """Substitute {port} and {env} (space-separated KEY=value pairs) in a launch command."""
    pairs = ' '.join(f'{k}={v}' for k, v in variables.items())
    return command.replace('{port}', str(port)).replace('{env}', pairs)


class Launched:
    """A running target process, its port and its captured output (stdout and stderr merged)."""

    def __init__(self, target, port, process, command):
        self.target = target
        self.port = port
        self.process = process
        self.command = command
        self.lines = []
        self.lock = threading.Lock()
        self.ready_line = threading.Event()
        self.alive_at_ready = True
        self.stopped = False
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for raw in iter(self.process.stdout.readline, b''):
            line = raw.decode(errors='replace').rstrip('\n')
            with self.lock:
                self.lines.append(line)
                if len(self.lines) > 5000:
                    del self.lines[:1000]
            if self.target.ready and self.target.ready in line:
                self.ready_line.set()
        self.process.stdout.close()

    def output(self, last=None):
        with self.lock:
            return list(self.lines[-last:] if last else self.lines)

    def exit_code(self):
        return self.process.poll()

    def crashed(self):
        """The process the app lives in has exited (only meaningful if it was alive once ready)."""
        return self.alive_at_ready and not self.stopped and self.process.poll() is not None

    def wait_ready(self):
        deadline = time.monotonic() + self.target.ready_timeout
        while time.monotonic() < deadline:
            code = self.process.poll()
            line_ok = self.target.ready is None or self.ready_line.is_set()
            if line_ok and port_open(self.port):
                self.alive_at_ready = code is None
                return
            if code is not None and code != 0:
                break
            if code is not None and self.target.ready and not self.ready_line.is_set():
                break  # A launcher that exits must have printed its ready line first.
            time.sleep(0.02)
        code = self.process.poll()
        reason = f'exited with code {code}' if code is not None else f'not ready after {self.target.ready_timeout:g}s'
        self.stop()
        tail = '\n'.join('    ' + line for line in self.output(20))
        raise TargetError(f'Target {self.target.name!r} {reason}: {self.command}' + (f'\n  output:\n{tail}' if tail else ''))

    def stop(self):
        if self.stopped:
            return
        self.stopped = True
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                self.process.wait()
        else:
            # The launcher exited; anything it left in its group still goes.
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        if self.target.stop:
            subprocess.run(self.target.stop, shell=True, cwd=self.target.root, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=60, check=False)
        self.reader.join(timeout=1)


def launch(target, network=None, cassettes=None, seed=None, port=None, faults=None, latency=None):
    """Start a fresh process for `target` and wait until it is ready. With `port = "auto"`, a launch
    that fails because another process took the free port meanwhile is retried on a new one."""
    for attempt in range(3):
        try:
            return _launch(target, network, cassettes, seed, port, faults, latency)
        except TargetError as error:
            if port is not None or target.port != 'auto' or 'already in use' not in str(error) or attempt == 2:
                raise


def _launch(target, network, cassettes, seed, port, faults, latency=None):
    if port is None:
        port = free_port() if target.port == 'auto' else target.port
    variables = dict(target.env)
    variables.update(run_environment(network, cassettes, seed, port, faults, latency))
    command = expand(target.launch, port, variables)
    environment = dict(os.environ, TCA_HARNESS='1', **variables)
    try:
        process = subprocess.Popen(command, shell=True, cwd=target.root, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as error:
        raise TargetError(f'Cannot launch target {target.name!r}: {error}') from None
    launched = Launched(target, port, process, command)
    launched.wait_ready()
    return launched


def quote(path):
    """Shell-quote a path for a launch command (used by tests and generated configs)."""
    return shlex.quote(str(path))
