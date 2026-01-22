set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-eu-west-3}"
PROJECT_TAG="${PROJECT_TAG:-ReplicaSafeEKS}"
ENV_TAG="${AWS_PROFILE:-dev}"

usage() {
  cat <<'H'
Usage:
  ./bin/rsedp audit 

cost audit (lists remaining AWS resources; used after destroy / to catch leaks)
H
}


echo "==> cost audit (read-only)"
echo "Region: ${REGION}"
echo "Project tag: ${PROJECT_TAG}"
echo "Environment tag: ${ENV_TAG}"  

aws() { command aws --region "${REGION}" "$@"; }

section () {
  echo
  echo "----------------------------------"
  echo "$1"
  echo "----------------------------------"
}

# EKS clusters
section "EKS clusters"
aws eks list-clusters --output table || true

# EC2 instances (filtered by tags)
section "EC2 instances"
aws ec2 describe-instances \
    --filters \
        "Name=tag:Project,Values=${PROJECT_TAG}" \
        "Name=tag:Environment,Values=${ENV_TAG}" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].{
        Id: InstanceId,
        State: State.Name,
        Type: InstanceType,
        AZ: Placement.AvailabilityZone,
        Name: Tags[?Key=='Name']|[0].Value
    }" \
    --output table || true

# NAT Gateways 
section "NAT Gateways (all)"

aws ec2 describe-nat-gateways \
    --filter "Name=state,Values=available,pending" \
    --query "NatGateways[].{
        Id:NatGatewayID,
        State:State,
        Subnet:SubnetId,
        Vpc:VpcId,
        PublicIp:NatGatewayAddresses[0].PublicIp
    }" \
    --output table || true

# Load Balancers
section "Load Balancers (ELBv2: ALB/NLB)"
aws elbv2 describe-load-balancers \
    --query "LoadBalancers[].{
        Name:LoadBalancerName,
        Type:Type,
        State:State.Code,
        Scheme:Scheme,
        DNSName:DNSName
    }" \
    --output table || true

# EBS volumes (filtered by tags)
section "EBS volumes"
aws ec2 describe-volumes \
    --filters \
        "Name=tag:Project,Values=${PROJECT_TAG}" \
        "Name=tag:Environment,Values=${ENV_TAG}" \
    --query "Volumes[].{
        Id:VolumeId,
        State:State,
        Type:VolumeType,
        SizeGB:Size,
        AZ:AvailabilityZone 
    }" \
    --output table || true

# RDS instances (filtered by tags)
section "RDS instances"
aws rds describe-db-instances \
    --query "Volumes[].{
        Id:VolumeId,
        State:State,
        Type:VolumeType,
        SizeGB:Size,
        AZ:AvailabilityZone
    }" \
    --output table || true

echo 
echo "==> Done."
echo "If anything above exists when you're not working, destroy dev env:"
echo "  ./scripts/destroy-dev-env.sh"