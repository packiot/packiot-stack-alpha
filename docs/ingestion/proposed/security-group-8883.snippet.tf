# PROPOSAL — do NOT terraform apply. ADR-0032 Path B public MQTT port.
# Add this ingress block to aws_security_group.app in
# terraform/staging/security_groups.tf ONLY after design §8 sign-off, and ONLY
# with real customer egress CIDRs (never 0.0.0.0/0 — a broker is a richer target
# than a single POST endpoint; the shim's tee-doc already asks for the egress IP).
# See docs/ingestion/mqtt-ingress-design.md §3.4.
#
# Precedent: the existing AMQPS rule ("factory edge clients publishing to
# RabbitMQ via Nginx TLS proxy", security_groups.tf:33) exposes 5671 the same way.

# ingress {
#   description = "MQTT-over-TLS (mTLS) - factory edge Node-RED publishing SparkPlug B (ADR-0032 Path B)"
#   from_port   = 8883
#   to_port     = 8883
#   protocol    = "tcp"
#   cidr_blocks = [
#     # "<CPACK factory egress>/32",
#     # "<INCOPLAST factory egress>/32",
#   ]
# }
#
# Alternative: front with a dedicated NLB (L4 TCP passthrough) so TLS/mTLS stay
# end-to-end to the broker. ALB cannot be used (HTTP/L7 only). NLB keeps the
# broker's client-cert identity intact — no PROXY-protocol needed for mTLS.
