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
  description = "Approximate AWS bill for the production-dryrun environment"
  value = {
    app_ec2_on_demand = "~$24.00  (t4g.medium on-demand, 730h)"
    ebs_volume        = "$5.12    (64GB gp3)"
    secrets_manager   = "$2.80    (~7 secrets × $0.40/secret/mo)"
    route53           = "$0.50    (hosted zone)"
    cloudwatch        = "~$2.00   (basic ingestion + alarm)"
    aws_backup        = "~$5.00   (daily EBS snapshots, 30d retention, ~64GB delta)"
    data_transfer     = "~$1.00   (egress estimate, low for dry-run with no real load)"
    s3_db_backups     = "$0       (bucket exists; objects ~zero in dry-run)"
    total             = "~$40/mo (vs staging ~$41/mo; slightly cheaper — no NAT, no DB EC2)"
  }
}
