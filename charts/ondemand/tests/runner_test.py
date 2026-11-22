"""Exercise the static runner with mocked Kubernetes discovery, no extra packages."""
import json
import os
import pathlib
import shutil
import ssl
import subprocess
import time
import unittest.mock as mock
import urllib.request

chart = pathlib.Path(__file__).resolve().parents[1]
source = (chart / "files/apps/jupyter/runner.sh").read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
compile(source, "runner.sh/python", "exec")
data = {}
responses = [
    {"status": {"hostIP": "10.0.1.5"}},
    {"spec": {"ports": [{"nodePort": 30001}]}},
]
calls = []

def read_text(path, *args, **kwargs):
    if path.name == "token":
        return "api-token"
    return data[str(path)]

def write_text(path, text, *args, **kwargs):
    data[str(path)] = text

def replace(path, destination):
    data[str(destination)] = data.pop(str(path))

def urlopen(request, **kwargs):
    assert request.get_header("Authorization") == "Bearer " + read_text(pathlib.Path("token"))
    assert kwargs["timeout"] == 10
    calls.append(request.full_url)
    response = mock.MagicMock()
    response.__enter__.return_value.read.return_value = json.dumps(responses.pop(0))
    return response

environment = {
    "OOD_SESSION_ROOT": "/home/ondemand/session", "OOD_SECONDS": "3600",
    "OOD_INTERFACE": "lab", "OOD_TOKEN": "a" * 64,
    "POD_NAMESPACE": "portal-ondemand-jobs-ondemand", "POD_NAME": "jupyter-abcd",
}
with mock.patch.dict(os.environ, environment), \
     mock.patch.object(pathlib.Path, "read_text", read_text), \
     mock.patch.object(pathlib.Path, "write_text", write_text), \
     mock.patch.object(pathlib.Path, "replace", replace), \
     mock.patch.object(ssl, "create_default_context", return_value=object()), \
     mock.patch.object(urllib.request, "urlopen", urlopen), \
     mock.patch.object(os, "execvp") as execute:
    exec(compile(source, "runner.sh/python", "exec"), {})
    execute.assert_called_once_with("jupyter", ["jupyter", "lab", "--config=/home/ondemand/session/jupyter.json"])
configuration = json.loads(data["/home/ondemand/session/jupyter.json"])
assert configuration["ServerApp"]["base_url"] == "/node/10.0.1.5/30001/"
assert configuration["ServerApp"]["port"] == 8888
assert configuration["IdentityProvider"]["token"] == "a" * 64
assert configuration["ServerApp"]["allow_remote_access"]
assert "disable_check_xsrf" not in configuration["ServerApp"]
assert data["/home/ondemand/session/host_ip"] == "10.0.1.5"
assert calls[1].endswith("/services/jupyter-abcd-service")
print("PASS: stdlib Kubernetes discovery, identity headers, exact NodePort base URL and strong token")

work = chart / "tests/work"
try:
    home = work / "home"
    output = work / "output"
    home.mkdir(parents=True)
    output.mkdir()
    batch_source = (chart / "files/apps/batch/runner.sh").read_text().replace("/home/ondemand", str(home))
    environment = dict(os.environ, OOD_SESSION_ROOT=str(output),
                       OOD_SCRIPT_PATH="example.sh", OOD_SECONDS="1")
    for content, expected in (("echo success\n", 0), ("exit 7\n", 7), ("sleep 30\n", 124)):
        (home / "example.sh").write_text(content)
        started = time.monotonic()
        result = subprocess.run(["bash"], input=batch_source, text=True, env=environment, timeout=5)
        assert result.returncode == expected
        assert (output / "exit_status").read_text().strip() == str(expected)
        assert time.monotonic() - started < 5
    print("PASS: batch runner success/failure exit_status and enforced one-second timeout")
finally:
    shutil.rmtree(work, ignore_errors=True)
