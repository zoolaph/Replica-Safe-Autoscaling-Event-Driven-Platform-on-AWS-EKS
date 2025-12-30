set -euo pipefail 

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${ROOT_DIR}/infra/environments/dev"

if [[ ! -d "${ENV_DIR}" ]]; then
    echo "ERROR: Environment directory '${ENV_DIR}' does not exist."
    echo "Nothing to destroy."
    exist 1
fi

if [[ ! -f "${ENV_DIR}/terraform.tfstate" && ! -d "${ENV_DIR}/.terraform" ]]; then
    echo "No Terraform state found in '${ENV_DIR}'. Nothing to destroy."    
    exit 0
fi

echo "Destroying infrastructure in environment form: ${ENV_DIR}"
cd "${ENV_DIR}"

terraform destroy -auto-approve

echo "Infrastructure destroyed."
echo "NOTE: Remote backend resources (S3 state bucket + DynamoDB lock table) are intentionally NOT destroyed."
echo "Verify in AWS that EKS/VPC/NAT/EC2/LB are gone."