output "app_public_ip" {
  description = "Static IP of the Production EC2 (same as all service A records)"
  value       = aws_eip.app.public_ip
}

output "route53_nameservers" {
  description = <<-EOT
    DNS delegation for prod.packiot.app.
    Terraform auto-wires the NS records into the parent packiot.app zone
    (Route53-managed). No manual register.it step required, unlike the
    register.it-managed staging.packiot.com setup.
    Propagation typically completes within minutes; full TTL is 24-48h.
  EOT
  value       = aws_route53_zone.production.name_servers
}

output "service_urls" {
  description = "HTTPS URLs for each production service (behind Nginx + Authentik SSO)"
  value       = { for svc in keys(var.services) : svc => "https://${svc}.${var.production_domain}" }
}

output "nginx_auth_credentials" {
  description = "How to retrieve Nginx basic auth credentials"
  value       = "aws secretsmanager get-secret-value --secret-id packiot/production/nginx-auth --region ${var.aws_region} --query SecretString --output text"
}

output "ssm_connect_app" {
  description = "Connect to Production EC2 via SSM (no SSH/bastion needed)"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}

output "ssm_connect_db" {
  description = "Connect to the dedicated DB EC2 via SSM (private subnet, no SSH/public IP)"
  value       = "aws ssm start-session --target ${aws_instance.db.id} --region ${var.aws_region}"
}

output "db_private_ip" {
  description = "Private IP of the dedicated DB EC2 — the target for the compose DATABASE_URL / pgbouncer upstream (W1 repoint)"
  value       = aws_instance.db.private_ip
}

output "ingest_endpoint" {
  description = "mTLS SparkPlug uplink endpoint the client-edge agent (bundle #624) dials. Port stays closed until client_ingest_egress_cidrs is filled + client tee scheduled."
  value       = "ssl://${var.ingest_subdomain}.${var.production_domain}:${var.ingest_mqtts_port}"
}

output "github_runner_next_step" {
  description = "How to activate the GitHub Actions self-hosted runner"
  value       = <<-EOT
    1. Create a classic GitHub PAT with 'repo' scope at:
       https://github.com/settings/tokens/new
    2. Run:
         aws secretsmanager put-secret-value \
           --secret-id packiot/production/github-runner \
           --secret-string '{"pat":"ghp_YOURTOKEN","repo":"${var.github_repo}"}' \
           --region ${var.aws_region}
    3. SSM into the App EC2 and run: sudo /opt/packiot/register-runner.sh
       (the script calls the GitHub API to get a fresh 1-hour token from the PAT)
    4. After ADR-0006 phase 1 lands, this PAT-based pattern gets replaced
       with OIDC at job time. Until then, mirrors the staging onboarding.
  EOT
}

output "rescue_root_password_retrieval" {
  description = "How to retrieve the EC2 Serial Console rescue root password"
  value       = "aws secretsmanager get-secret-value --secret-id packiot/production/ec2-rescue --region ${var.aws_region} --query SecretString --output text"
}

output "db_backup_bucket_name" {
  description = "S3 bucket for nightly pg_dump backups (starts empty in dry-run phase)"
  value       = aws_s3_bucket.db_backups.bucket
}

output "estimated_monthly_cost" {
  description = "Approximate AWS bill for the production environment (post W2 ingest + W6 DB split)"
  value = {
    app_ec2_on_demand = "~$24.00  (t4g.medium on-demand, 730h — bump to t4g.large in W6.3 once the 8 extra services land)"
    app_ebs_volume    = "$5.12    (64GB gp3)"
    db_ec2_on_demand  = "~$118.00 (r7g.large 16GB on-demand, 730h; ~$236 if bumped to r7g.xlarge)"
    db_ebs_volume     = "~$13.00  (100GB gp3 + 1000 provisioned IOPS + 125 extra MB/s over baseline)"
    nat_instance      = "~$3.00   (t4g.nano on-demand for private-subnet egress)"
    secrets_manager   = "$2.80    (~7 secrets × $0.40/secret/mo; +per-tenant cert secrets when issued)"
    route53           = "$0.50    (hosted zone)"
    cloudwatch        = "~$3.00   (basic ingestion + 2 disk alarms)"
    aws_backup        = "~$9.00   (daily EBS snapshots of app + DB, 30d retention)"
    data_transfer     = "~$2.00   (egress estimate; real client uplink is small SparkPlug deltas)"
    s3_db_backups     = "$0       (bucket exists; pg_dump path is a W1 follow-up)"
    total             = "~$180/mo once the DB EC2 + NAT are applied (dominated by the r7g the roadmap requires; the t4g.medium local-DB topology it replaces is the one that swap-died)"
  }
}
