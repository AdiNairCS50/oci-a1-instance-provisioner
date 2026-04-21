#!/usr/bin/env bash
# Provisions a single VM.Standard.A1.Flex instance within Oracle Cloud Always Free Tier limits.
#
# Always Free A1 limits (as of 2026):
#   Shape:   VM.Standard.A1.Flex only
#   OCPUs:   4 total across ALL A1 instances in the tenancy
#   Memory:  24 GB total across ALL A1 instances in the tenancy
#   Storage: 200 GB block volume total; minimum boot volume 47 GB per instance
#   Idle:    Oracle may reclaim if CPU p95 < 20% for 7 consecutive days

set -uo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────

echo_output() {
  echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# ── Always Free constants — do not change ─────────────────────────────────────

readonly SHAPE="VM.Standard.A1.Flex"
readonly FREE_OCPUS=4
readonly FREE_MEMORY_GB=24
readonly FREE_BOOT_VOL_GB=47   # OCI minimum; well within 200 GB free storage quota

# ── Pre-flight: quota check ───────────────────────────────────────────────────
# Count OCPUs already allocated to live A1 instances.
# Abort if we are already at the free limit to avoid triggering paid charges.

echo "--- Pre-flight: checking existing A1 quota ---"

EXISTING_OCPUS=$(oci compute instance list \
  --compartment-id "$COMPARTMENT_ID" \
  --query "data[?shape=='${SHAPE}' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [].\"shape-config\".ocpus" \
  --raw-output 2>/dev/null \
  | python3 -c "import sys,json; data=json.load(sys.stdin); print(int(sum(data)))" 2>/dev/null \
  || echo "0")

echo "Existing A1 OCPUs in use: ${EXISTING_OCPUS} / ${FREE_OCPUS}"

if [ "${EXISTING_OCPUS}" -ge "${FREE_OCPUS}" ]; then
  echo "Already at Always Free A1 quota (${FREE_OCPUS} OCPUs)."
  echo "Check the OCI Console and terminate any unneeded instances before retrying."
  echo_output "result" "quota_exceeded"
  exit 0
fi

# ── Idempotency: skip if our instance already exists ─────────────────────────

echo ""
echo "--- Checking for existing 'pmtradingbot' instance ---"

EXISTING_ID=$(oci compute instance list \
  --compartment-id "$COMPARTMENT_ID" \
  --display-name "pmtradingbot" \
  --query "data[?\"lifecycle-state\"=='RUNNING'] | [0].id" \
  --raw-output 2>/dev/null || echo "")

if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
  echo "Instance already running: $EXISTING_ID"
  PUBLIC_IP=$(oci compute instance list-vnics \
    --instance-id "$EXISTING_ID" \
    --query 'data[0]."public-ip"' \
    --raw-output 2>/dev/null || echo "check console")
  echo "Public IP: $PUBLIC_IP"
  echo_output "result" "success"
  echo_output "public_ip" "$PUBLIC_IP"
  exit 0
fi

# ── Launch: try each availability domain in sequence ─────────────────────────

IFS=',' read -ra ADS <<< "$AVAILABILITY_DOMAINS"
CAPACITY_FAILURES=0

for AD in "${ADS[@]}"; do
  AD="${AD// /}"
  echo ""
  echo "--- Trying: $AD ---"

  LAUNCH_OUTPUT=$(oci compute instance launch \
    --availability-domain     "$AD" \
    --compartment-id          "$COMPARTMENT_ID" \
    --shape                   "$SHAPE" \
    --shape-config            "{\"ocpus\":${FREE_OCPUS},\"memoryInGBs\":${FREE_MEMORY_GB}}" \
    --image-id                "$IMAGE_ID" \
    --subnet-id               "$SUBNET_ID" \
    --assign-public-ip        true \
    --display-name            "pmtradingbot" \
    --boot-volume-size-in-gbs "${FREE_BOOT_VOL_GB}" \
    --freeform-tags           '{"FreeTier":"true","Project":"pmtradingbot"}' \
    --metadata                "{\"ssh_authorized_keys\":\"${SSH_PUBLIC_KEY}\"}" \
    2>&1) && LAUNCH_EXIT=0 || LAUNCH_EXIT=$?

  if [ $LAUNCH_EXIT -eq 0 ]; then
    INSTANCE_ID=$(echo "$LAUNCH_OUTPUT" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || echo "")

    echo "SUCCESS — instance created in $AD"
    echo "Instance ID: $INSTANCE_ID"

    # Wait for VNIC to attach before querying public IP
    sleep 20
    PUBLIC_IP=$(oci compute instance list-vnics \
      --instance-id "$INSTANCE_ID" \
      --query 'data[0]."public-ip"' \
      --raw-output 2>/dev/null || echo "check console")

    echo "Public IP: $PUBLIC_IP"
    echo_output "result" "success"
    echo_output "public_ip" "$PUBLIC_IP"
    exit 0
  fi

  if echo "$LAUNCH_OUTPUT" | grep -qiE "out of host capacity|InternalError|capacity"; then
    echo "No capacity in $AD — trying next"
    CAPACITY_FAILURES=$((CAPACITY_FAILURES + 1))
  else
    echo "Unexpected error in $AD:"
    echo "$LAUNCH_OUTPUT"
    echo_output "result" "error"
    exit 1
  fi
done

echo ""
echo "No capacity in any availability domain (${CAPACITY_FAILURES}/${#ADS[@]} tried)"
echo "Will retry on next schedule run."
echo_output "result" "capacity"
exit 0
