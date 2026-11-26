#!/usr/bin/env python3
"""A fake Oracle Cloud instance metadata service for the boot test.

QEMU runs it per guest connection (guestfwd=...-cmd:), so it talks HTTP on
stdin and stdout (stderr is the same socket). Serves the instance document Afterburn reads and the
Ignition config (the file named by the first argument, base64 encoded as OCI
stores user data) at the paths of the v2 API (with or without a trailing slash).
"""
import base64
import http.server
import json
import os
import sys

USER_DATA = base64.b64encode(open(sys.argv[1], "rb").read())
INSTANCE = {
    "id": "ocid1.instance.oc1..boottest",
    "displayName": "boot-test",
    "hostname": "boot-test",
    "region": "phx",
    "canonicalRegionName": "us-phoenix-1",
    "availabilityDomain": "AD-1",
    "faultDomain": "FAULT-DOMAIN-1",
    "compartmentId": "ocid1.compartment.oc1..boottest",
    "shape": "BM.Standard.E2.64",
    "metadata": {"ssh_authorized_keys": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl boot-test"},
}
ROUTES = {
    "/opc/v2/instance": ("application/json", json.dumps(INSTANCE).encode()),
    "/opc/v2/instance/metadata/user_data": ("text/plain", USER_DATA),
    "/opc/v2/vnics": ("application/json", b"[]"),
}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        self.rfile = sys.stdin.buffer
        self.wfile = os.fdopen(1, "wb", buffering=0)

    def finish(self):
        pass

    def do_GET(self):
        route = ROUTES.get(self.path.rstrip("/"))
        if route is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", route[0])
        self.send_header("Content-Length", str(len(route[1])))
        self.end_headers()
        self.wfile.write(route[1])

    def log_message(self, fmt, *args):
        # QEMU gives the command one socket as stdin, stdout and stderr: no logging.
        pass


Handler(None, ("guest", 0), None)
