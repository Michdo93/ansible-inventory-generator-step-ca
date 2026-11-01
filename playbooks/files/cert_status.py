#!/usr/bin/env python3
"""Report the SSH host keys of this host and the state of their certificates as JSON."""
import glob
import json
import re
import subprocess
import time

result = []
for pub in sorted(glob.glob("/etc/ssh/ssh_host_*_key.pub")):
    cert = pub[:-4] + "-cert.pub"
    entry = {"pub": pub, "cert": cert, "pubkey": open(pub).read().strip(),
             "exists": False, "valid_to": 0, "ca_fp": "", "principals": []}
    try:
        out = subprocess.run(["ssh-keygen", "-L", "-f", cert], capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        result.append(entry)
        continue
    entry["exists"] = True
    m = re.search(r"Valid: .*? to (\S+)", out)
    if m and m.group(1) == "forever":
        entry["valid_to"] = 2 ** 62
    elif m:
        entry["valid_to"] = int(time.mktime(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")))
    m = re.search(r"Signing CA: \S+ (SHA256:\S+)", out)
    entry["ca_fp"] = m.group(1) if m else ""
    m = re.search(r"Principals:\s*\n((?:\s{16}\S.*\n)*)", out)
    entry["principals"] = sorted(p.strip() for p in m.group(1).splitlines()) if m else []
    result.append(entry)
print(json.dumps({"now": int(time.time()), "keys": result}))
