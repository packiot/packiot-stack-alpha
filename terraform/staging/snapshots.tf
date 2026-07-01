# ── AWS Backup plan for EC2 root-volume snapshots ─────────────────────────────
# Daily snapshots of the app EC2 root volume + 7-day retention. Bridges the
# operational gap exposed by the 2026-06-22 disk-full incident: when
# /var/lib/docker filled and docker.service refused to start, every in-band
# recovery path (SSM, SSH, EC2 Instance Connect) went dark. The 25-min EBS
# detach-attach-rescue we did would have been a 2-min snapshot restore
# with this in place.
#
# Why AWS Backup vs DLM (Data Lifecycle Manager): AWS Backup is one
# integrated console for snapshots + cross-account/region copy + audit
# reports + restore testing. DLM is older, snapshot-only, and the two
# can't share lifecycle rules. The op-team preference is whichever console
# already shows the DB pg_dump pipeline; AWS Backup wins because we can
# later add the DB EC2 to the same plan and inherit the same retention.
#
# The DB EC2 is intentionally NOT included here yet — it has its own
# nightly pg_dump → S3 pipeline (terraform/staging/backups.tf) which is
# more useful for actual point-in-time recovery than an EBS snapshot.
# When the DB grows past 64G, revisit and add the DB EC2 to this plan as
# a second selection.
#
# ADR-0011 P0-2 coverage (2026-07-01): the mosquitto data volume
# (Docker named volume `mosquitto-data` from compose.staging.yml) lives
# at /var/lib/docker/volumes/ on the app EC2's ROOT EBS (vol-083e14a9…).
# The selection below targets the whole EC2 by tag — AWS Backup snapshots
# ALL attached EBS volumes for a tagged instance — so retained Sparkplug
# NBIRTHs persist across broker restart AND are recoverable if the app
# EC2 root disk fails. No separate resource needed for Mosquitto.
# If a future refactor moves mosquitto-data to a dedicated EBS volume,
# THAT volume will need a `Backup=daily` tag + a second aws_backup_selection.

# ── Backup vault ──────────────────────────────────────────────────────────────
# Vault is the namespaced storage for recovery points. Default account-level
# vault works fine for one EC2; naming explicit keeps the relationship
# discoverable in the AWS Backup console alongside any future plans.
resource "aws_backup_vault" "ec2_snapshots" {
  name = "packiot-staging-ec2-snapshots"

  tags = {
    Name    = "packiot-staging-ec2-snapshots"
    Purpose = "EBS snapshot retention for staging app EC2"
  }
}

# ── Backup plan: daily, 7-day retention ───────────────────────────────────────
# Cron syntax is AWS Backup-flavoured (6-field with year). 03:00 UTC matches
# the existing pg_dump cadence at 02:00 UTC + the pg_cron cleanup at 03:00 UTC
# so all data-protection work happens in a single off-hours window.
resource "aws_backup_plan" "ec2_daily" {
  name = "packiot-staging-ec2-daily"

  rule {
    rule_name         = "daily-7d-retention"
    target_vault_name = aws_backup_vault.ec2_snapshots.name
    schedule          = "cron(0 3 * * ? *)"

    # Window-of-tolerance: if AWS Backup can't start within this window
    # (e.g. service throttling), skip rather than back up at a random time
    # later. 1 h start + 4 h completion gives a generous buffer for
    # incremental snapshots that should complete in seconds.
    start_window      = 60
    completion_window = 240

    lifecycle {
      # Cold storage would cost more than warm for 7-day retention; skip.
      delete_after = 7
    }

    recovery_point_tags = {
      Plan = "packiot-staging-ec2-daily"
    }
  }

  tags = {
    Name = "packiot-staging-ec2-daily"
  }
}

# ── IAM role AWS Backup assumes to take snapshots ─────────────────────────────
# Two managed policies cover the full lifecycle: AWSBackupServiceRolePolicyForBackup
# for creating + listing + deleting recovery points; ...ForRestores for
# restoring them when we need to. Skipping the restore policy would let
# us take backups but force operators to manually re-create the IAM
# context during an incident — exactly the wrong tradeoff.
resource "aws_iam_role" "backup" {
  name = "packiot-staging-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "backup.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "packiot-staging-backup-role"
  }
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
# Targeted by tag rather than ARN so a future replacement instance with
# the same Name tag is picked up automatically — important because EC2
# instance IDs change on replace but the role they play (staging app
# host) does not.
resource "aws_backup_selection" "app_ec2" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "packiot-staging-app-ec2"
  plan_id      = aws_backup_plan.ec2_daily.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Name"
    value = "packiot-staging-app"
  }
}

output "ec2_backup_vault" {
  value       = aws_backup_vault.ec2_snapshots.name
  description = "AWS Backup vault holding daily EBS snapshots of the staging app EC2."
}
