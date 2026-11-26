#!/usr/bin/env bash
set -euo pipefail
umask 077
exec >>"${OOD_SESSION_ROOT}/output.log" 2>&1

# Publish this session's NodePort endpoint and password for the dashboard card.
python3 - <<'PY'
import ipaddress
import json
import os
import pathlib
import ssl
import time
import urllib.error
import urllib.request

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

def create_connection_secret(host, port, password):
    secret = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": pod_name + "-secret"},
        "type": "Opaque",
        "stringData": {
            "host_ip": host,
            "node_port": str(port),
            "password": password,
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

password = os.environ["OOD_PASSWORD"]
if len(password) != 8 or not password.isascii() or not password.isalnum():
    raise ValueError("Invalid session password")
create_connection_secret(host, port, password)
root = pathlib.Path(os.environ["OOD_SESSION_ROOT"])
(root / "host_ip").write_text(host)
(root / "node_port").write_text(str(port))
PY

# Classic VNC authentication; the VNC server stays loopback-only behind websockify.
vnc=""
for candidate in Xvnc Xtigervnc; do
  if command -v "$candidate" >/dev/null 2>&1; then vnc="$candidate"; break; fi
done
[[ -n "$vnc" ]] || { echo "No Xvnc server found"; exit 1; }
passwd_tool=""
for candidate in vncpasswd tigervncpasswd; do
  if command -v "$candidate" >/dev/null 2>&1; then passwd_tool="$candidate"; break; fi
done
[[ -n "$passwd_tool" ]] || { echo "No vncpasswd tool found"; exit 1; }
printf '%s\n' "${OOD_PASSWORD}" | "$passwd_tool" -f >"${OOD_SESSION_ROOT}/vncpasswd"
"$vnc" :1 -geometry 1600x900 -depth 24 -rfbport 5901 -localhost \
  -SecurityTypes VncAuth -rfbauth "${OOD_SESSION_ROOT}/vncpasswd" &

ready=""
for _ in $(seq 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/5901) 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[[ -n "$ready" ]] || { echo "Xvnc did not become ready"; exit 1; }

export DISPLAY=:1
session=""
for candidate in startxfce4 xfce4-session mate-session startlxqt icewm-session xterm; do
  if command -v "$candidate" >/dev/null 2>&1; then session="$candidate"; break; fi
done
[[ -n "$session" ]] || { echo "No desktop session command found"; exit 1; }
"$session" &

web=""
for candidate in /usr/share/novnc /usr/local/share/novnc /usr/share/webapps/novnc /opt/novnc /headless/noVNC; do
  if [[ -f "${candidate}/vnc_lite.html" ]]; then web="$candidate"; break; fi
done
[[ -n "$web" ]] || { echo "No noVNC web root with vnc_lite.html found"; exit 1; }

# The portal's /node proxy forwards the full original path; mirror the
# /node/<host>/<port> prefix in the served web root.
host_ip=$(<"${OOD_SESSION_ROOT}/host_ip")
node_port=$(<"${OOD_SESSION_ROOT}/node_port")
[[ "$host_ip" =~ ^[0-9][0-9.]+$ && "$node_port" =~ ^[0-9]+$ ]] || { echo "Invalid discovered endpoint"; exit 1; }
webroot="/tmp/ood-web"
mkdir -p "${webroot}/node/${host_ip}"
ln -sfn "$web" "${webroot}/node/${host_ip}/${node_port}"

# Only the websockify HTTP/WebSocket listener is reachable through the NodePort.
exec timeout --signal=TERM --kill-after=30s "${OOD_SECONDS}s" \
  websockify --web "$webroot" 8888 127.0.0.1:5901
