module github.com/packiot/packiot-stack-alpha/services/edge-transformer

go 1.24

// Dependency set mirrors services/oeecloud-worker/go.mod verbatim — same
// AWS SDK v2, same amqp091-go, same prometheus client, same slog (stdlib),
// same golang.org/x/sync for errgroup. ADR-0009 Errata Correction 2: "Any
// pattern from oeecloud-worker or mirror-worker-go MUST NOT be re-implemented
// in edge-transformer." Locked deps make pattern drift detectable.
//
// pgx is intentionally NOT included in this skeleton — Phase 2 will add it
// only if the transformer needs DB access for tenant discovery. Today the
// tenant set is read from a YAML file on disk (clientconfig package).
require (
	github.com/aws/aws-sdk-go-v2/config v1.32.25
	github.com/aws/aws-sdk-go-v2/service/secretsmanager v1.42.3
	github.com/prometheus/client_golang v1.23.2
	github.com/rabbitmq/amqp091-go v1.10.0
	golang.org/x/sync v0.16.0
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/aws/aws-sdk-go-v2 v1.42.0 // indirect
	github.com/aws/aws-sdk-go-v2/credentials v1.19.24 // indirect
	github.com/aws/aws-sdk-go-v2/feature/ec2/imds v1.18.29 // indirect
	github.com/aws/aws-sdk-go-v2/internal/configsources v1.4.29 // indirect
	github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 v2.7.29 // indirect
	github.com/aws/aws-sdk-go-v2/internal/v4a v1.4.30 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding v1.13.12 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/presigned-url v1.13.29 // indirect
	github.com/aws/aws-sdk-go-v2/service/signin v1.2.0 // indirect
	github.com/aws/aws-sdk-go-v2/service/sso v1.31.3 // indirect
	github.com/aws/aws-sdk-go-v2/service/ssooidc v1.36.6 // indirect
	github.com/aws/aws-sdk-go-v2/service/sts v1.43.3 // indirect
	github.com/aws/smithy-go v1.27.1 // indirect
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/kr/text v0.2.0 // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/prometheus/client_model v0.6.2 // indirect
	github.com/prometheus/common v0.66.1 // indirect
	github.com/prometheus/procfs v0.16.1 // indirect
	go.yaml.in/yaml/v2 v2.4.2 // indirect
	golang.org/x/sys v0.35.0 // indirect
	google.golang.org/protobuf v1.36.8 // indirect
)
