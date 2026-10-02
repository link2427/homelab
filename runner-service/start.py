"""Keep the edge and loopback API in one pod; fail the container if either exits."""
import signal
import subprocess
import time

children = [subprocess.Popen(["/usr/local/bin/vulcan-edge"]),
            subprocess.Popen(["uvicorn", "app:app", "--host", "127.0.0.1", "--port", "8000", "--no-access-log", "--no-proxy-headers"])]


def stop(*_):
    for child in children:
        child.terminate()


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    while all(child.poll() is None for child in children):
        time.sleep(0.2)
finally:
    stop()
    for child in children:
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
raise SystemExit(1)
