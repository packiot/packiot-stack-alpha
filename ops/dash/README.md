# Service dashboard (`dash.packiot.app`)

Static internal service directory — login links for every staging + production
service, grouped by environment, behind the production Cognito SSO gate.

- **Served from:** `/var/www/dash/index.html` on the **production app box**
  (`packiot-production-app`), via the `dash.conf` nginx vhost written by
  `terraform/production/user_data/nginx_setup.sh` (hand-managed HTTP-01 cert;
  Cognito `auth_request` gate, same cs-admin group as the admin UIs).
- **Source of truth:** this `ops/dash/index.html`. It is NOT auto-deployed (no CI
  hook) — it's a hand-managed static page.

## Deploy / update

Edit `ops/dash/index.html`, then copy it to the prod box (SSM or scp), keeping a
timestamped backup:

```sh
# via SSM (base64 to survive the transport)
B64=$(base64 -w0 ops/dash/index.html)
aws ssm send-command --instance-ids <prod-app-id> --document-name AWS-RunShellScript \
  --parameters "commands=[\"cp /var/www/dash/index.html /var/www/dash/index.html.bak.\$(date +%s); echo $B64 | base64 -d > /var/www/dash/index.html\"]"
```

nginx serves it statically (no reload needed). Verify a logged-in load of
`https://dash.packiot.app`.

## Keeping it current

When a service is added/removed/renamed, update the relevant env section here.
Cross-check against the live service set: staging `terraform/staging/variables.tf`
`var.services` + the nginx vhosts; prod `terraform/production/variables.tf`. Probe
`https://<svc>.<env>.packiot.app` (200/302 = exists behind the gate; connection
failure = absent).
