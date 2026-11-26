#!/usr/bin/env bash
set -euo pipefail
umask 077
exec >>"${OOD_SESSION_ROOT}/output.log" 2>&1
exec timeout --signal=TERM --kill-after=30s "${OOD_SECONDS}s" python3 - <<'PY'
import ipaddress
import json
import os
import pathlib
import re
import ssl
import time
import urllib.error
import urllib.request

root = pathlib.Path(os.environ["OOD_SESSION_ROOT"])
identity = pathlib.Path("/var/run/secrets/kubernetes.io/serviceaccount")
context = ssl.create_default_context(cafile=str(identity / "ca.crt"))
namespace = os.environ["POD_NAMESPACE"]
pod_name = os.environ["POD_NAME"]
api = "https://kubernetes.default.svc/api/v1/namespaces/" + namespace

def get(resource):
    request = urllib.request.Request(api + "/" + resource)
    request.add_header("Authorization", "Bearer " + (identity / "token").read_text().strip())
    with urllib.request.urlopen(request, context=context, timeout=10) as response:
        return json.load(response)

def create_connection_secret(host, port, token, interface_path):
    secret = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": pod_name + "-secret"},
        "type": "Opaque",
        "stringData": {
            "host_ip": host,
            "node_port": str(port),
            "token": token,
            "interface_path": interface_path,
        },
    }
    request = urllib.request.Request(
        api + "/secrets",
        data=json.dumps(secret).encode(),
        headers={
            "Authorization": "Bearer " + (identity / "token").read_text().strip(),
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, context=context, timeout=10) as response:
        response.read()

for attempt in range(60):
    try:
        pod = get("pods/" + pod_name)
        service = get("services/" + pod_name + "-service")
        host = str(ipaddress.IPv4Address(pod["status"]["hostIP"]))
        port = int(service["spec"]["ports"][0]["nodePort"])
        if not 1 <= port <= 65535:
            raise ValueError("Invalid NodePort")
        break
    except (urllib.error.URLError, KeyError, IndexError, ValueError):
        if attempt == 59:
            raise
        time.sleep(2)

base = f"/node/{host}/{port}/"
token = os.environ["OOD_TOKEN"]
if len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
    raise ValueError("Invalid session token")
mode = os.environ["OOD_INTERFACE"]
if mode not in ("lab", "notebook"):
    raise ValueError("Invalid interface")
interface_path = "tree" if mode == "notebook" else "lab"
create_connection_secret(host, port, token, interface_path)
# Proxied write requests carry the portal's Origin while Host stays the
# NodePort endpoint; pin the exact portal origin so Jupyter accepts them.
origin = os.environ["OOD_PORTAL_ORIGIN"]
if not re.fullmatch(r"https://[A-Za-z0-9.-]+(?::\d{1,5})?", origin):
    raise ValueError("Invalid portal origin")
configuration = {
    "ServerApp": {
        "ip": "0.0.0.0", "port": 8888, "port_retries": 0,
        "open_browser": False, "base_url": base,
        "root_dir": "/home/ondemand", "allow_remote_access": True,
        "trust_xheaders": True, "allow_origin": origin
    },
    "IdentityProvider": {"token": token}
}
config = root / "jupyter.json"
config.write_text(json.dumps(configuration))
# Keep the API token out of the served page config: if JupyterLab sets its own
# Authorization header, browsers drop the portal's Basic credentials and the
# Apache proxy rejects every API call. Lab then authenticates by cookie.
labconfig = root / "jupyter-config" / "labconfig"
labconfig.mkdir(parents=True, exist_ok=True)
(labconfig / "page_config.json").write_text('{"token": ""}')
os.environ["JUPYTER_CONFIG_DIR"] = str(root / "jupyter-config")
os.execvp("jupyter", ["jupyter", mode, "--config=" + str(config)])
PY
