# ── AWS Backup plan for EC2 root-volume snapshots ─────────────────────────────
# Daily snapshots of the production EC2 root volume + 30-day retention.
# Longer than staging's 7 days because production data — once it lands in
# phase 2/3 — has a longer recovery window expectation.
#
# Mirrors the pattern justified in staging's snapshots.tf comment block
# (post 2026-06-22 disk-full incident): EBS snapshot restore is a 2-min
# recovery path vs the 25-min EBS detach-attach-rescue we did manually
# in that incident.

resource "aws_backup_vault" "ec2_snapshots" {
  name = "packiot-production-ec2-snapshots"

  tags = {
    Name    = "packiot-production-ec2-snapshots"
    Purpose = "EBS snapshot retention for production app EC2"
  }
}

# ── Backup plan: daily, 30-day retention ─────────────────────────────────────
# Cron is AWS Backup-flavoured (6-field with year). 04:00 UTC — one hour
# after staging's 03:00 UTC window so AWS Backup's per-account concurrency
# isn't a contention point.

resource "aws_backup_plan" "ec2_daily" {
  name = "packiot-production-ec2-daily"

  rule {
    rule_name         = "daily-${var.ec2_backup_retention_days}d-retention"
    target_vault_name = aws_backup_vault.ec2_snapshots.name
    schedule          = "cron(0 4 * * ? *)"

    # Window-of-tolerance: if AWS Backup can't start within this window
    # (e.g. service throttling), skip rather than back up at a random later
    # time. 1 h start + 4 h completion gives buffer for incremental
    # snapshots that should complete in seconds.
    start_window      = 60
    completion_window = 240

    lifecycle {
      # 30-day retention — costs ~4× staging's 7-day cohort, still cheap
      # in absolute terms (gp3 snapshot pricing is per-GB-month delta).
      delete_after = var.ec2_backup_retention_days
    }

    recovery_point_tags = {
      Plan = "packiot-production-ec2-daily"
    }
  }

  tags = {
    Name = "packiot-production-ec2-daily"
  }
}

# ── IAM role AWS Backup assumes to take snapshots ─────────────────────────────
# Both managed policies for the full lifecycle: ...ForBackup for create
# + list + delete; ...ForRestores for restoring during an incident.
# Skipping the restore policy would force operators to re-create the IAM
# context during an emergency — exactly the wrong tradeoff.

resource "aws_iam_role" "backup" {
  name = "packiot-production-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "packiot-production-backup-role" }
}

resource "aws_iam_role_policy_attachment" "backup_backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ── Selection: the app EC2 ────────────────────────────────────────────────────
# Targeted by tag rather than ARN — future replacement instance with the
# same Name tag is picked up automatically (EC2 instance IDs change on
# replace; role doesn't).

resource "aws_backup_selection" "app_ec2" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "packiot-production-app-ec2"
  plan_id      = aws_backup_plan.ec2_daily.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Name"
    value = "packiot-production-app"
  }
}

output "ec2_backup_vault" {
  value       = aws_backup_vault.ec2_snapshots.name
  description = "AWS Backup vault holding daily EBS snapshots of the production app EC2."
}
