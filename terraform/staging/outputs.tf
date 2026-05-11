output "app_public_ip" {
  description = "Static IP of the App EC2 (same as all service A records)"
  value       = aws_eip.app.public_ip
}

output "db_private_ip" {
  description = "Private IP of the DB EC2 (used by App EC2 Docker services)"
  value       = aws_instance.db.private_ip
}

output "route53_nameservers" {
  description = <<-EOT
    ⚠️  REQUIRED MANUAL STEP:
    Add these 4 NS records at register.it for the subdomain staging.packiot.com.
    Use record type NS, one per nameserver. DNS delegation takes 24-48h.
  EOT
  value       = aws_route53_zone.staging.name_servers
}

output "service_urls" {
  description = "HTTPS URLs for each staging service (available after DNS delegation + cert issue)"
  value       = { for svc in keys(var.services) : svc => "https://${svc}.${var.staging_domain}" }
}

output "ssm_connect_app" {
  description = "Connect to App EC2 via SSM (no SSH/bastion needed)"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}

output "ssm_connect_db" {
  description = "Connect to DB EC2 via SSM"
  value       = "aws ssm start-session --target ${aws_instance.db.id} --region ${var.aws_region}"
}

output "github_runner_next_step" {
  description = "How to activate the GitHub Actions self-hosted runner"
  value       = <<-EOT
    1. Go to: https://github.com/${var.github_repo}/settings/actions/runners/new
    2. Copy the registration token
    3. Run:
         aws secretsmanager put-secret-value \
           --secret-id packiot/staging/github-runner \
           --secret-string '{"registration_token":"<TOKEN>","repo":"${var.github_repo}"}' \
           --region ${var.aws_region}
    4. SSM into the App EC2 and run: sudo /opt/packiot/register-runner.sh
  EOT
}

output "estimated_monthly_cost" {
  description = "Approximate AWS bill for this staging environment"
  value = {
    db_ec2_on_demand = "$24.00  (t4g.medium, 730h)"
    app_ec2_spot     = "~$7.00  (t4g.medium spot, ~70% discount)"
    fck_nat_ec2      = "$3.00   (t4g.nano, 730h)"
    ebs_total        = "$2.40   (20GB + 10GB gp3)"
    secrets_manager  = "$1.20   (4 secrets × $0.40/secret/mo)"
    route53          = "$0.50   (hosted zone)"
    cloudwatch_logs  = "~$2.00  (basic ingestion)"
    data_transfer    = "~$1.00  (egress estimate)"
    total            = "~$41/mo"
  }
}
