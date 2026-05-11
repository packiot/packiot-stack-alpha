output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "next_step" {
  value = <<-EOT
    Bootstrap complete. Now run from terraform/staging/:

      terraform init \
        -backend-config="bucket=${aws_s3_bucket.state.bucket}" \
        -backend-config="key=staging/terraform.tfstate" \
        -backend-config="region=us-east-1" \
        -backend-config="dynamodb_table=${aws_dynamodb_table.lock.name}" \
        -backend-config="encrypt=true"
  EOT
}
