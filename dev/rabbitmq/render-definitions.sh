#!/bin/sh
# Dev twin of deploy-staging.yml's "Generate RabbitMQ definitions" step.
#
# Staging renders monitoring/rabbitmq/definitions.template.json with jq and
# passwords from Secrets Manager. Dev renders dev/rabbitmq/definitions.dev.template.json
# (staging's users/permissions/policy PLUS the `oee` topology stream-engine
# declares in code) with sed and the fake passwords from dev/.env.dev, then
# hands off to the image's normal entrypoint. monitoring/rabbitmq/rabbitmq.conf
# (shared with staging, unchanged) points load_definitions at the output path.
set -eu

: "${RMQ_ADMIN_USER:?}" "${RMQ_ADMIN_PASS:?}" "${RMQ_STREAM_ENGINE_PASS:?}" "${RMQ_SD_PASS:?}"

sed -e "s|__ADMIN_PASS__|${RMQ_ADMIN_PASS}|g" \
    -e "s|__ADMIN__|${RMQ_ADMIN_USER}|g" \
    -e "s|__OEE_PASS__|${RMQ_STREAM_ENGINE_PASS}|g" \
    -e "s|__SD_PASS__|${RMQ_SD_PASS}|g" \
    /etc/rabbitmq/definitions.template.json > /etc/rabbitmq/definitions.json
chmod 0644 /etc/rabbitmq/definitions.json

exec docker-entrypoint.sh rabbitmq-server
