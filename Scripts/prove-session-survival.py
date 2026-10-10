#!/usr/bin/env python3
"""Isolated lifecycle proof. Never connects to an existing Harness home or service.

Proves guarded owner restarts and, when available, lossless application-daemon handover.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import tempfile
import time
import shutil


def until(condition, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.04)
    raise RuntimeError("proof deadline exceeded")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=Path(__file__).resolve().parents[1] / ".build/debug")
    args = parser.parse_args()
    daemon = args.bin_dir.resolve() / "HarnessDaemon"
    cli = args.bin_dir.resolve() / "harness-cli"
    with tempfile.TemporaryDirectory(prefix="hproof-", dir="/tmp") as directory:
        root = Path(directory)
        environment = {**os.environ, "HARNESS_HOME": directory, "SHELL": "/bin/sh", "HARNESS_SERVER": str(root / "harness.sock")}
        log = (root / "proof.log").open("wb")
        stream = None
        owner = subprocess.Popen([str(daemon)], env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log)

        def request(method, values=None):
            data = json.dumps({"request": {method: values or {}}}).encode()
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(30)
                connection.connect(str(root / "harness.sock"))
                connection.sendall(struct.pack(">I", len(data)) + data)

                def read(count):
                    result = bytearray()
                    while len(result) < count:
                        chunk = connection.recv(count - len(result))
                        if not chunk:
                            raise RuntimeError("service closed an incomplete response")
                        result.extend(chunk)
                    return result

                return json.loads(read(struct.unpack(">I", read(4))[0]))["response"]

        def ready():
            try:
                return "pong" in request("ping")
            except (OSError, RuntimeError):
                return False

        try:
            until(ready)
            mcp = subprocess.run(["python3", str(Path(__file__).with_name("prove-mcp.py")), "--cli", str(cli), "--socket", str(root / "harness.sock")], env=environment, capture_output=True, text=True, timeout=25)
            assert mcp.returncode == 0, mcp.stderr + mcp.stdout
            mcp_evidence = json.loads(mcp.stdout)
            # Public forwarding must retain the local-only administration boundary.
            with socket.socket(socket.AF_UNIX) as remote_control:
                remote_control.settimeout(5)
                remote_control.connect(str(root / "harness.sock"))
                def remote_request(value):
                    encoded = json.dumps({"request": value}).encode()
                    remote_control.sendall(struct.pack(">I", len(encoded)) + encoded)
                    def read_remote(count):
                        result = bytearray()
                        while len(result) < count:
                            chunk = remote_control.recv(count - len(result))
                            if not chunk:
                                raise RuntimeError("remote boundary response truncated")
                            result.extend(chunk)
                        return result
                    length = struct.unpack(">I", read_remote(4))[0]
                    return json.loads(read_remote(length))["response"]
                assert "ok" in remote_request({"presentClient": {"kind": "proof", "version": "fixture", "uid": os.getuid(), "tunnel": True}})
                assert "error" in remote_request({"activity": {"_0": {"schedules": {"requestID": "00000000-0000-0000-0000-000000000011", "operation": {"list": {"offset": 0, "limit": 10}}}}}})
                assert "error" in remote_request({"activity": {"_0": {"notifications": {"_0": {"status": {}}}}}})
                assert "pong" in remote_request({"ping": {}})
            initial = request("daemonStats")["daemonStats"]["_0"]
            assert initial["pid"] == owner.pid
            surface = request("createSurface", {"cwd": directory, "shell": "/bin/sh"})["surfaceID"]["_0"]
            child = json.loads(request("processTree", {"surfaceID": surface})["text"]["_0"])["child"]["pid"]
            heartbeat = root / "heartbeat"
            job_pid_file = root / "job.pid"
            command = "export HARNESS_PROOF=preserved; (while :; do date +%s >> " + shlex.quote(str(heartbeat)) + "; sleep 0.2; done) & echo $! > " + shlex.quote(str(job_pid_file)) + "\n"
            request("send", {"surfaceID": surface, "text": command})
            until(lambda: heartbeat.exists() and job_pid_file.exists() and job_pid_file.read_text().strip().isdigit())
            job = int(job_pid_file.read_text().strip())
            refused = subprocess.run([str(cli), "daemon-restart", "--if-empty"], env=environment, capture_output=True, text=True, timeout=12)
            assert refused.returncode != 0 and "Preserved" in refused.stderr, refused.stderr
            os.kill(child, 0)
            os.kill(job, 0)
            assert owner.poll() is None
            competing = subprocess.run([str(daemon)], env=environment, capture_output=True, text=True, timeout=4)
            assert competing.returncode != 0
            assert int((root / "daemon.pid").read_text()) == owner.pid
            marker = root / "state"
            request("send", {"surfaceID": surface, "text": "printf '%s' \"$HARNESS_PROOF\" > " + shlex.quote(str(marker)) + "\n"})
            until(lambda: marker.exists() and marker.read_text() == "preserved")
            assert marker.read_text() == "preserved"
            assert request("daemonStats")["daemonStats"]["_0"]["pid"] == owner.pid
            host = initial.get("sessionHostPID")
            pipe_pid_file = root / "pipe.pid"
            pipe_output = root / "pipe.output"
            if host:
                pipe_command = "echo $$ > " + shlex.quote(str(pipe_pid_file)) + "; exec cat > " + shlex.quote(str(pipe_output))
                assert "ok" in request("pipePane", {"surfaceID": surface, "shellCommand": pipe_command})
                until(lambda: pipe_pid_file.exists() and pipe_pid_file.read_text().strip().isdigit())
                pipe_pid = int(pipe_pid_file.read_text())
                # A harmless owned provider-shaped process supplies a real ancestry
                # and kernel generation; a shell PID is not a provider identity.
                fixture_binary = root / "claude"
                shutil.copyfile("/bin/sleep", fixture_binary); fixture_binary.chmod(0o700)
                fixture_pid_file = root / "fixture-agent.pid"
                request("send", {"surfaceID": surface, "text": shlex.quote(str(fixture_binary)) + " 3600 & echo $! > " + shlex.quote(str(fixture_pid_file)) + "\n"})
                until(lambda: fixture_pid_file.exists() and fixture_pid_file.read_text().strip().isdigit())
                fixture_agent = int(fixture_pid_file.read_text().strip())
                # Harmless provider fixtures exercise the durable execution reducer and
                # its memory checkpoint when this unsigned proof cannot access Keychain.
                def fixture_hook(kind, event_name, turn):
                    observation = {"contract": "claude-hooks-2026-10", "eventName": event_name,
                                   "kind": kind, "conversationID": "proof-conversation", "turnID": turn,
                                   "reportedAt": time.time() - 978307200}
                    report = {"surfaceID": surface, "senderPID": fixture_agent, "profile": "default",
                              "observation": observation}
                    result = request("activity", {"_0": {"hook": {"_0": report}}})
                    assert "text" in result, result
                    return json.loads(result["text"]["_0"])

                execution = fixture_hook("turnStarted", "UserPromptSubmit", "proof-turn")
                stopped = fixture_hook("turnCompleted", "Stop", "proof-turn")
                assert stopped["id"] == execution["id"] and stopped["process"] == "running"
                assert stopped["turn"] == "completed" and "endedAt" not in stopped
                bounds = {"from": time.time() - 86400 - 978307200, "to": time.time() + 86400 - 978307200}
                digest = json.loads(request("activity", {"_0": {"digest": {**bounds, "surfaceID": None}}})["text"]["_0"])
                reports = json.loads(request("activity", {"_0": {"repositoryDigest": {"requestID": "11111111-2222-4333-8444-555555555555", **bounds, "offset": 0, "limit": 100}}})["text"]["_0"])
                assert reports["hostID"] == digest["hostID"] and "nextOffset" not in reports
                for metric in ["executions", "turnsCompleted", "turnsFailed", "toolsStarted", "toolsCompleted"]:
                    assert sum(report["totals"][metric] for report in reports["reports"]) == digest["totals"][metric]
                assert all(not usage["limits"] for report in reports["reports"] for usage in report["usage"])


                def recorded_execution():
                    result = request("activity", {"_0": {"session": {"runID": execution["id"], "offset": 0, "limit": 100}}})
                    assert "text" in result, result
                    return json.loads(result["text"]["_0"])

                assert len(recorded_execution()["events"]) == 2
                before = request("daemonStats")["daemonStats"]["_0"]
                stream = socket.socket(socket.AF_UNIX)
                stream.settimeout(5)
                stream.connect(str(root / "harness.sock"))
                attach = json.dumps({"request": {"attachStream": {"_0": {"surfaceID": surface, "readOnly": True, "history": False, "geometryEvents": True}}}}).encode()
                stream.sendall(struct.pack(">I", len(attach)) + attach)

                def stream_read(count):
                    result = bytearray()
                    while len(result) < count:
                        chunk = stream.recv(count - len(result))
                        if not chunk:
                            raise RuntimeError("terminal stream was lost during handover")
                        result.extend(chunk)
                    return bytes(result)

                last_stream_end = 0
                def stream_frame():
                    nonlocal last_stream_end
                    first = stream_read(1)
                    if first == b"\xf5":
                        length = struct.unpack(">I", stream_read(4))[0]
                        sequence = struct.unpack(">Q", stream_read(8))[0]
                        payload = stream_read(length - 8)
                        assert sequence >= last_stream_end, "terminal bytes duplicated or reordered"
                        last_stream_end = sequence + len(payload)
                        return payload
                    length = struct.unpack(">I", first + stream_read(3))[0]
                    return json.loads(stream_read(length))["response"]

                attached = stream_frame()
                assert "attached" in attached, attached
                last_stream_end = attached["attached"]["_0"]["endSequence"]
                assert "ok" in request("resizeSurface", {"surfaceID": surface, "rows": 31, "cols": 99})
                assert "ok" in request("send", {"surfaceID": surface, "text": "printf '\\nRECORD_GEOMETRY_AFTER\\n'\n"})
                geometry_seen = False
                geometry_output = bytearray()
                while b"RECORD_GEOMETRY_AFTER" not in geometry_output:
                    frame = stream_frame()
                    if isinstance(frame, dict) and "terminalResize" in frame:
                        size = frame["terminalResize"]["_0"]
                        if size["rows"] == 31 and size["cols"] == 99:
                            assert size["sequence"] >= last_stream_end
                            geometry_seen = True
                    elif isinstance(frame, bytes):
                        geometry_output.extend(frame)
                assert geometry_seen, "ordered actual PTY resize was not delivered before output"
                failed = request("replaceDaemon", {"executable": "/usr/bin/false"})
                assert "error" in failed, failed
                assert request("daemonStats")["daemonStats"]["_0"]["daemonPID"] == before["daemonPID"]
                os.kill(child, 0); os.kill(job, 0)
                # A compatible fixture gets through warming, then fails activation after
                # lease transfer. It owns no PTYs and never connects to a real home.
                fixture = root / "failed-activation"
                fixture_pid = root / "candidate.pid"
                fixture_stats = {"response": {"daemonStats": {"_0": before}}}
                fixture_snapshot = {"response": request("getSnapshot")}
                fixture.write_text("#!/usr/bin/env python3\n" + "import json,os,socket,struct\n"
                    + "path=os.environ['HARNESS_DAEMON_SOCKET']\n"
                    + "open(" + repr(str(fixture_pid)) + ",'w').write(str(os.getpid()))\n"
                    + "listener=socket.socket(socket.AF_UNIX);listener.bind(path);listener.listen(8)\n"
                    + "stats=" + repr(fixture_stats) + "\n"
                    + "snapshot=" + repr(fixture_snapshot) + "\n"
                    + "def read(c,n):\n r=b''\n while len(r)<n:\n  chunk=c.recv(n-len(r))\n  if not chunk: raise EOFError()\n  r+=chunk\n return r\n"
                    + "while True:\n c,_=listener.accept()\n try:\n  req=json.loads(read(c,struct.unpack('>I',read(c,4))[0]))['request']\n"
                    + "  value=stats if 'daemonStats' in req else snapshot if 'getSnapshot' in req else {'response':{'error':{'_0':'fixture activation refused'}}}\n"
                    + "  data=json.dumps(value).encode();c.sendall(struct.pack('>I',len(data))+data)\n"
                    + " except (EOFError,OSError): pass\n finally: c.close()\n")
                fixture.chmod(0o700)
                activation_refused = request("replaceDaemon", {"executable": str(fixture)})
                assert "error" in activation_refused and "previous daemon was restored" in activation_refused["error"]["_0"], activation_refused
                assert request("daemonStats")["daemonStats"]["_0"]["daemonPID"] == before["daemonPID"]
                assert recorded_execution()["run"]["id"] == execution["id"]
                try:
                    os.kill(int(fixture_pid.read_text()), 0)
                    raise AssertionError("failed candidate was still alive after rollback")
                except ProcessLookupError:
                    pass
                os.kill(child, 0); os.kill(job, 0)
                result = request("replaceDaemon", {"executable": str(daemon)})
                assert "ok" in result, result
                after = request("daemonStats")["daemonStats"]["_0"]
                assert after["pid"] == before["pid"] and after["daemonPID"] != before["daemonPID"]
                assert after["epoch"] == before["epoch"]
                assert recorded_execution()["run"]["id"] == execution["id"]
                assert len(recorded_execution()["events"]) == 2
                os.kill(child, 0); os.kill(job, 0); os.kill(pipe_pid, 0)
                marker.unlink()
                request("send", {"surfaceID": surface, "text": "printf '%s' \"$HARNESS_PROOF\" > " + shlex.quote(str(marker)) + "\n"})
                until(lambda: marker.exists() and marker.read_text() == "preserved")
                assert marker.read_text() == "preserved"
                request("send", {"surfaceID": surface, "text": "printf '\\nHOST_STREAM_SURVIVED\\n'\n"})
                output = bytearray()
                while b"HOST_STREAM_SURVIVED" not in output:
                    frame = stream_frame()
                    if isinstance(frame, bytes):
                        output.extend(frame)
                # Exercise daemon failure using the same shell, job and attachment.
                # Allow its immediate checkpoint publication to commit before the crash.
                time.sleep(1.1)
                os.kill(after["daemonPID"], 9)
                until(lambda: request("daemonStats")["daemonStats"]["_0"].get("daemonPID") not in (None, after["daemonPID"]))
                assert recorded_execution()["run"]["id"] == execution["id"]
                os.kill(child, 0); os.kill(job, 0); os.kill(pipe_pid, 0)
                marker.unlink()
                request("send", {"surfaceID": surface, "text": "printf '%s' \"$HARNESS_PROOF\" > " + shlex.quote(str(marker)) + "\n"})
                until(lambda: marker.exists() and marker.read_text() == "preserved")
                assert marker.read_text() == "preserved"
                assert "ok" in request("send", {"surfaceID": surface, "text": "printf '\\nPIPE_SURVIVED_REPLACEMENT_AND_CRASH\\n'\n"})
                until(lambda: pipe_output.exists() and "PIPE_SURVIVED_REPLACEMENT_AND_CRASH" in pipe_output.read_text())
                assert "ok" in request("pipePane", {"surfaceID": surface, "shellCommand": None})
                until(lambda: not Path("/proc/" + str(pipe_pid)).exists() if os.uname().sysname == "Linux" else subprocess.run(["/bin/kill", "-0", str(pipe_pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0)
                stream.close(); stream = None
            uncertain_home = root / "uncertain"
            uncertain_home.mkdir()
            (uncertain_home / "harness.sock").write_text("unverified prior owner")
            uncertain = subprocess.run([str(daemon)], env={**environment, "HARNESS_HOME": str(uncertain_home)},
                                       capture_output=True, text=True, timeout=4)
            assert uncertain.returncode != 0
            assert not (uncertain_home / "daemon.pid").exists()
            assert not (uncertain_home / "sessions/layout.json").exists()
            request("closeSurface", {"surfaceID": surface})
            for item in request("listSurfaces")["surfaces"]["_0"]:
                request("send", {"surfaceID": item["surfaceID"], "text": "exit\n"})
            until(lambda: (lambda stats: stats["surfaceCount"] == 0 and stats.get("pipeConsumerCount", 0) == 0 and stats.get("pendingProcessRetirements", 0) == 0 and stats.get("pendingDaemonRetirements", 0) == 0)(request("daemonStats")["daemonStats"]["_0"]))
            restarted = subprocess.run([str(cli), "daemon-restart", "--if-empty"], env=environment, capture_output=True, text=True, timeout=15)
            assert restarted.returncode == 0, restarted.stderr
            until(ready)
            assert request("daemonStats")["daemonStats"]["_0"]["pid"] != owner.pid
            if host:
                fresh = request("daemonStats")["daemonStats"]["_0"]
                stale_worker, failed_owner = fresh["daemonPID"], fresh["sessionHostPID"]
                # This is the isolated owner created by the empty restart. Parent
                # loss must retire its worker without a stale persistence flush.
                os.kill(failed_owner, 9)
                def worker_gone():
                    try:
                        os.kill(stale_worker, 0)
                        if __import__('sys').platform.startswith('linux'):
                            # A container's PID 1 may retain an already terminated
                            # orphan as a zombie. It has no descriptors or mutation lease.
                            try:
                                state = Path('/proc/' + str(stale_worker) + '/stat').read_text().rsplit(')', 1)[1].split()[0]
                                if state in ('Z', 'X'):
                                    return True
                            except FileNotFoundError:
                                return True
                        return False
                    except ProcessLookupError:
                        return True
                until(worker_gone, timeout=5)
                owner = subprocess.Popen([str(daemon)], env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                until(ready)
                recovered = request("daemonStats")["daemonStats"]["_0"]
                assert recovered["sessionHostPID"] == owner.pid and recovered["daemonPID"] != stale_worker
            print(json.dumps({"active_shell_preserved": True, "background_job_preserved": True,
                              "shell_environment_preserved": True, "competing_start_refused": True,
                              "uncertain_owner_preserved": True, "empty_restart_succeeded": True,
                              "failed_candidate_retained_owner": bool(host), "failed_activation_rolled_back": bool(host), "daemon_replaced_without_process_loss": bool(host),
                              "terminal_attachment_preserved": bool(host), "pipe_consumer_preserved": bool(host), "daemon_crash_recovered": bool(host),
                              "activity_execution_preserved": bool(host), "recording_geometry_ordered": bool(host), "forwarded_local_admin_boundary": True, "host_loss_retires_mutating_worker": bool(host), "repository_digest_matches_host_totals": bool(host), "mcp": mcp_evidence,
                              "scope": "isolated session-host lifecycle" if host else "isolated monolithic update safety"}))
        except Exception:
            diagnostic = Path("/tmp") / (root.name + "-failure.log")
            log.flush(); shutil.copyfile(root / "proof.log", diagnostic); diagnostic.chmod(0o600)
            print("Isolated proof diagnostics: " + str(diagnostic), file=__import__("sys").stderr)
            raise
        finally:
            if stream is not None:
                stream.close()
            if ready():
                request("shutdownDaemon", {"requireEmpty": False})
                # Shutdown is acknowledged before the owner finishes draining. Wait
                # for that completion instead of killing the owner ahead of its worker.
                try: owner.wait(timeout=8)
                except subprocess.TimeoutExpired: pass
            if owner.poll() is None:
                owner.terminate()
            owner.wait(timeout=10)
            # Wait for the replacement's PID file to disappear before removing its home.
            until(lambda: not (root / "daemon.pid").exists())
            log.close()


if __name__ == "__main__":
    main()
