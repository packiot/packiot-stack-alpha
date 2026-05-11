output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "next_step" {
  value = "Run `make tf-init` from the repo root to configure the remote backend."
}
