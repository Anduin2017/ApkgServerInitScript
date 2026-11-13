# AnduinOS package mirror

Deploy a standalone mirror with incremental A/B synchronization, metadata
SHA256 verification, and atomic publication. Failed syncs keep the previous
repository available.

## Deploy

Run on a dedicated Ubuntu server with sudo access:

```sh
bash deploy-edge.sh
```

The default exposes HTTP on port 80 for the existing Cloudflare-backed nodes.
For a node that serves HTTPS directly:

```sh
bash deploy-edge.sh --https-domain packages.aiursoft.cn
```

Point the hostname's A record, and its AAAA record if IPv6 is configured, at
this server. Allow inbound TCP 80/443 and UDP 443 in the cloud firewall.
Caddy automatically obtains and renews certificates. Certificate and autosave
state persist under `/opt/anduinos-edge/caddy-data` and `caddy-config`, separately
from the read-only mirror data. On subsequent runs, `bash deploy-edge.sh`
reads the existing Caddyfile and preserves its HTTP or HTTPS mode and hostname.
Existing HTTP-only nodes need no new arguments. Use `--https-domain` to enable
HTTPS for the first time or explicitly change the hostname. Unrecognized site
configuration, or missing configuration with existing certificate state, stops
deployment before system changes instead of silently downgrading to HTTP.
Back up the certificate state alongside the deployment configuration.

The installer installs dependencies and Docker if needed, enables UFW, and
configures ports. Use a dedicated server rather than running it over unrelated
services. Docker Hub and `https://apkg-dav.aiursoft.com/` must be reachable.

Check synchronization and HTTPS after the initial publication:

```sh
sudo docker logs --tail 100 anduinos_sync
curl --fail https://packages.aiursoft.cn/sync_status.json
```

Wake an idle existing sync loop without redeploying:

```sh
bash deploy-edge.sh --sync-now
```
