#!/usr/bin/env bash
# provision-edge-ssm-iam.sh — codify the edge-api SSM control-plane IAM policy.
#
# ADR-0049 chose AWS SSM as the edge connectivity/deploy substrate. edge-api
# drives client factory boxes (hybrid managed instances, mi-*) via a dedicated
# low-privilege IAM user `packiot-edge-ssm` whose one attached policy,
# `packiot-edge-ssm-control`, is defined *here* as the single source of truth.
#
# The whole SSM substrate (user, policy, hybrid-registration role, activations)
# was originally stood up imperatively during the 2026-08-27 session. This
# script exists so the *policy document* is reproducible and reviewable in-repo
# rather than living only in the AWS console. It is idempotent: re-running it
# publishes the embedded document as a new default policy version (pruning the
# oldest non-default version if the 5-version IAM cap is hit).
#
# ── The gotcha this policy encodes (do NOT regress) ──────────────────────────
# `ssm:SendCommand` authorizes against BOTH resources in the request: the
# *document* (AWS-RunShellScript) AND the *target instance*. A single statement
# that scopes SendCommand with a `ssm:resourceTag/managed-by` Condition applies
# that Condition to the AWS-OWNED document too — which can never carry our tag —
# so the document leg is denied and every Box-Ops command fails with:
#   "not authorized to perform: ssm:SendCommand on resource
#    .../document/AWS-RunShellScript because no identity-based policy allows..."
# The fix (and the shape below): SPLIT into an UNCONDITIONAL document leg and a
# tag-GATED instance leg. Same pattern for ssm:StartSession (connect / port-
# forward) — its session documents likewise cannot carry the tag.
# The tag gate on the *instance* legs is what enforces least privilege: edge-api
# may only target managed instances tagged managed-by=packiot-edge-api (set at
# CreateActivation time, per client/enterprise).
#
# Usage: AWS_PROFILE=... ./scripts/provision-edge-ssm-iam.sh   (needs iam:* on
# this policy + the user). Region-agnostic (IAM is global); ARNs pin us-east-1
# for the SSM resources, matching the staging/prod stack.
set -euo pipefail

ACCOUNT_ID="639178078294"
REGION="us-east-1"
USER_NAME="packiot-edge-ssm"
POLICY_NAME="packiot-edge-ssm-control"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
HYBRID_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/packiot-edge-ssm-hybrid-role"

POLICY_DOC=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProvisionAndInventory",
      "Effect": "Allow",
      "Action": [
        "ssm:CreateActivation",
        "ssm:DescribeActivations",
        "ssm:DeleteActivation",
        "ssm:DescribeInstanceInformation",
        "ssm:DeregisterManagedInstance",
        "ssm:AddTagsToResource",
        "ssm:ListTagsForResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassHybridRoleToSSMOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "${HYBRID_ROLE_ARN}",
      "Condition": { "StringEquals": { "iam:PassedToService": "ssm.amazonaws.com" } }
    },
    {
      "Sid": "SendCommandDocument",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ssm:${REGION}::document/AWS-RunShellScript"
    },
    {
      "Sid": "SendCommandToTaggedInstances",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:managed-instance/*",
      "Condition": { "StringEquals": { "ssm:resourceTag/managed-by": "packiot-edge-api" } }
    },
    {
      "Sid": "ReadCommandResults",
      "Effect": "Allow",
      "Action": [
        "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations",
        "ssm:ListCommands"
      ],
      "Resource": "*"
    },
    {
      "Sid": "StartSessionDocuments",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ssm:${REGION}::document/AWS-StartPortForwardingSession",
        "arn:aws:ssm:${REGION}::document/SSM-SessionManagerRunShell"
      ]
    },
    {
      "Sid": "StartSessionToTaggedInstances",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:managed-instance/*",
      "Condition": { "StringEquals": { "ssm:resourceTag/managed-by": "packiot-edge-api" } }
    },
    {
      "Sid": "ManageOwnSessions",
      "Effect": "Allow",
      "Action": [
        "ssm:TerminateSession",
        "ssm:ResumeSession",
        "ssm:DescribeSessions"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)

echo ">> Ensuring policy ${POLICY_NAME} reflects the canonical document..."
if ! aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  echo ">> Policy absent — creating + attaching to user ${USER_NAME}."
  aws iam create-policy --policy-name "${POLICY_NAME}" \
    --policy-document "${POLICY_DOC}" >/dev/null
  aws iam attach-user-policy --user-name "${USER_NAME}" --policy-arn "${POLICY_ARN}"
else
  # Prune the oldest non-default version if we're at the 5-version cap.
  count=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
    --query 'length(Versions)' --output text)
  if [ "${count}" -ge 5 ]; then
    oldest=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
      --query 'sort_by(Versions[?IsDefaultVersion==`false`],&CreateDate)[0].VersionId' \
      --output text)
    echo ">> Pruning oldest non-default version ${oldest} (5-version cap)."
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${oldest}"
  fi
  echo ">> Publishing new default policy version."
  aws iam create-policy-version --policy-arn "${POLICY_ARN}" \
    --policy-document "${POLICY_DOC}" --set-as-default \
    --query 'PolicyVersion.VersionId' --output text
fi

echo ">> Done. Verify with:"
echo "   aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::${ACCOUNT_ID}:user/${USER_NAME} \\"
echo "     --action-names ssm:SendCommand --resource-arns arn:aws:ssm:${REGION}::document/AWS-RunShellScript"
