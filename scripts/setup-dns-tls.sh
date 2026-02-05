#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_DEFAULT_REGION:-eu-west-3}"

# You can set this if you already own a domain and want to use it:
#   export DOMAIN=example.com
DOMAIN="${DOMAIN:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'"; exit 1; }; }
need aws
need jq

echo "[INFO] Region: ${AWS_REGION}"

# 1) If DOMAIN not provided, try to pick an existing public hosted zone
if [[ -z "${DOMAIN}" ]]; then
  echo "[INFO] DOMAIN not set. Trying to detect an existing public hosted zone in Route53..."
  ZONES_JSON="$(aws route53 list-hosted-zones --output json)"
  # pick first public zone (not PrivateZone)
  DOMAIN="$(echo "${ZONES_JSON}" | jq -r '.HostedZones[] | select(.Config.PrivateZone==false) | .Name' | head -n1 | sed 's/\.$//')"
  if [[ -z "${DOMAIN}" || "${DOMAIN}" == "null" ]]; then
    echo
    echo "[FAIL] No public Route53 hosted zone found."
    echo "You need a real domain you control."
    echo "Best path: register a domain (Route53 or any registrar), then create a Route53 Public Hosted Zone for it."
    echo
    echo "Then run again with:"
    echo "  export DOMAIN=yourdomain.com"
    exit 1
  fi
  echo "[INFO] Using detected DOMAIN=${DOMAIN}"
fi

# 2) Find or create hosted zone for DOMAIN
HZ="$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}" --output json | jq -r '.HostedZones[] | select(.Name=="'"${DOMAIN}"'.") | .Id' | head -n1 | sed 's|/hostedzone/||')"
if [[ -z "${HZ}" || "${HZ}" == "null" ]]; then
  echo "[INFO] No hosted zone found for ${DOMAIN}. Creating one..."
  HZ="$(aws route53 create-hosted-zone --name "${DOMAIN}" --caller-reference "rsedp-$(date +%s)" \
    --output json | jq -r '.HostedZone.Id' | sed 's|/hostedzone/||')"
  echo "[INFO] Created hosted zone: ${HZ}"
else
  echo "[INFO] Found hosted zone: ${HZ}"
fi

# 3) Request ACM cert (DNS validation) for a demo hostname
DEMO_HOSTNAME="${DEMO_HOSTNAME:-demo.${DOMAIN}}"
echo "[INFO] Demo hostname: ${DEMO_HOSTNAME}"

CERT_ARN="$(aws acm request-certificate \
  --region "${AWS_REGION}" \
  --domain-name "${DEMO_HOSTNAME}" \
  --validation-method DNS \
  --output json | jq -r '.CertificateArn')"

echo "[INFO] Requested certificate ARN: ${CERT_ARN}"

echo
echo "Export these for the rest of the setup:"
echo "  export DOMAIN=${DOMAIN}"
echo "  export HOSTED_ZONE_ID=${HZ}"
echo "  export DEMO_HOSTNAME=${DEMO_HOSTNAME}"
echo "  export ACM_CERT_ARN=${CERT_ARN}"
echo
echo "[NEXT] You must create the ACM DNS validation record in Route53 (one-time)."
echo "Run:"
echo "  aws acm describe-certificate --region ${AWS_REGION} --certificate-arn ${CERT_ARN} --output json"
echo "Then add the ResourceRecord (CNAME) into hosted zone ${HZ} in Route53."
echo
echo "After validation, ACM will mark the cert as ISSUED."
