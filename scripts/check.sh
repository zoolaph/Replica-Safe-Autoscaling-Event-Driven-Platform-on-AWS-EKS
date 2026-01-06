
set -euo pipefail


PROFILE=dev REGION=eu-west-3 CLUSTER=replicasafe-dev PROJECT=ReplicaSafeEKS ENV=dev \
STATE_BUCKET="replicasafeeks-tfstate-021471808095-eu-west-3" \
LOCK_TABLE="replicasafeeks-tflock-021471808095-eu-west-3" \


echo "== Identity =="
aws sts get-caller-identity --profile "$PROFILE"

echo
echo "== EKS =="
if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1; then
  echo "EKS cluster EXISTS: $CLUSTER"
  echo -n "Nodegroups: "
  aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --profile "$PROFILE" --query "nodegroups[]" --output text || true
else
  echo "EKS cluster NOT FOUND: $CLUSTER"
fi

echo
echo "== Tagged resources (quick sweep) =="
TAGGED_COUNT=$(aws resourcegroupstaggingapi get-resources --region "$REGION" --profile "$PROFILE" \
  --tag-filters "Key=Project,Values=$PROJECT" "Key=Env,Values=$ENV" \
  --query "length(ResourceTagMappingList[])" --output text)
echo "Tagging API count(Project=$PROJECT, Env=$ENV): $TAGGED_COUNT"
if [ "$TAGGED_COUNT" != "0" ]; then
  aws resourcegroupstaggingapi get-resources --region "$REGION" --profile "$PROFILE" \
    --tag-filters "Key=Project,Values=$PROJECT" "Key=Env,Values=$ENV" \
    --query "ResourceTagMappingList[].ResourceARN" --output text
fi

echo
echo "== VPCs (by tags Project/Env) =="
VPCS=$(aws ec2 describe-vpcs --region "$REGION" --profile "$PROFILE" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Env,Values=$ENV" \
  --query "Vpcs[].VpcId" --output text)

if [ -z "${VPCS:-}" ]; then
  echo "No VPCs found with Project=$PROJECT and Env=$ENV"
else
  echo "VPCs: $VPCS"
  for vpc in $VPCS; do
    echo
    echo "-- VPC $vpc dependency counts --"
    echo -n "Subnets:            "; aws ec2 describe-subnets --region "$REGION" --profile "$PROFILE" --filters "Name=vpc-id,Values=$vpc" --query "length(Subnets[])" --output text
    echo -n "RouteTables:        "; aws ec2 describe-route-tables --region "$REGION" --profile "$PROFILE" --filters "Name=vpc-id,Values=$vpc" --query "length(RouteTables[])" --output text
    echo -n "InternetGateways:   "; aws ec2 describe-internet-gateways --region "$REGION" --profile "$PROFILE" --filters "Name=attachment.vpc-id,Values=$vpc" --query "length(InternetGateways[])" --output text
    echo -n "NAT Gateways:       "; aws ec2 describe-nat-gateways --region "$REGION" --profile "$PROFILE" --filter "Name=vpc-id,Values=$vpc" --query "length(NatGateways[])" --output text
    echo -n "VPC Endpoints:      "; aws ec2 describe-vpc-endpoints --region "$REGION" --profile "$PROFILE" --filters "Name=vpc-id,Values=$vpc" --query "length(VpcEndpoints[])" --output text
    echo -n "SecurityGroups:     "; aws ec2 describe-security-groups --region "$REGION" --profile "$PROFILE" --filters "Name=vpc-id,Values=$vpc" --query "length(SecurityGroups[])" --output text
    echo -n "NetworkInterfaces:  "; aws ec2 describe-network-interfaces --region "$REGION" --profile "$PROFILE" --filters "Name=vpc-id,Values=$vpc" --query "length(NetworkInterfaces[])" --output text
    echo -n "ELBv2 LoadBalancers:"; aws elbv2 describe-load-balancers --region "$REGION" --profile "$PROFILE" --query "length(LoadBalancers[?VpcId==\`$vpc\`])" --output text
  done
fi

echo
echo "== Backend sanity (bucket + lock table) =="
if aws s3api head-bucket --bucket "$STATE_BUCKET" --profile "$PROFILE" >/dev/null 2>&1; then
  echo "S3 bucket EXISTS: $STATE_BUCKET"
  echo -n "Objects under environments/dev/: "
  aws s3api list-objects-v2 --bucket "$STATE_BUCKET" --prefix "environments/dev/" --profile "$PROFILE" --query "length(Contents[])" --output text 2>/dev/null || echo "0"
else
  echo "S3 bucket NOT FOUND: $STATE_BUCKET"
fi

if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1; then
  echo "DynamoDB lock table EXISTS: $LOCK_TABLE"
else
  echo "DynamoDB lock table NOT FOUND: $LOCK_TABLE"
fi

echo
echo "== IAM quick scan (names containing replicasafe / cluster name) =="
echo -n "Roles:   "
aws iam list-roles --profile "$PROFILE" \
  --query "Roles[?contains(RoleName, \`replicasafe\`) || contains(RoleName, \`$CLUSTER\`)].RoleName" --output text || true
echo -n "Policies:"
aws iam list-policies --profile "$PROFILE" --scope Local \
  --query "Policies[?contains(PolicyName, \`replicasafe\`) || contains(PolicyName, \`$CLUSTER\`)].PolicyName" --output text || true

echo
echo "DONE. If EKS=NOT FOUND, VPC list is empty, all per-VPC counts are 0, and backend is NOT FOUND => clean slate."
