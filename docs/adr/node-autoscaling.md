# ADR: Node autoscaling choice (Cluster Autoscaler vs karpenter)

**Status:** Accepted
**Date:** 2026-01-09
**Owner:** RepicaSafeEKS
**Decision:** **Adopt Cluster Autoscaler** for node autoscaling in this project 
**Not chosen:** **Karpenter**

---

## Context 

ReplicaSafeEKS is an event-driven autoscaling platform on EKS. We already have:
- EKS cluster + managed node group (MNG) baseline
- Storage (EBS CSI) + Metrics Server
- Ingress (AWS Load Balancer Controller)

Next, we need **node autoscaling** to ensure the cluster can:
- scale out when pods are pending 
- scale in to reduce cost when demand drops

This is required to make later steps (HPA/KEDA) ciable, otherwise pods can become Pending indefinitely.

---

## Decision drivers 

1. **Complexity** MVP-first
2. **Operability** less moving parts, easier to debug
3. **Cost controls** predictable, safe defauts, fits destroy/rebuild workflow
4. **IAM blast radius** least privilege, minimal AWS API permissions
5. **Demo** easy to prove scale up/down reliably
6. **Compatibility with existing setup** EKS Managed node group already in place

---

## Options considered

### Option A - Cluster Autoscaler (CA)
**How it works:** watches for unschedulable pods; scales EC2 Auto Scaling Groups/ node groups to fit them. :contentReference[oaicite:0]{index=0}
**AWS EKS integration:** Recommended patterns included using ASG autodiscovery via tags. :contentRefence[oaicite:1]{index=1}

**Pros**
- Fastest path with our current MNG setup ( CA scales the undelying ASGs).
- Simple conceptual model: "Pending pods -> add node(s)".
- IAM scope can be imited to ASG/EC2 read + ASG scaling actions.
- Demo is straightforward and reproducible.

**Cons**
- Scaling behavior is bounded by node group shapes (instance types and configuration of ASG/MNG).
- Less flexible than karpenter for bin-packing and instance-type selection.

## Option B - Karpenter
**How it works:** Provisions nodes based on pod scheduling needs (instance type, AZs, etc.). :contentReference[oaicite:2]{index=2}  
**AWS EKS integration:** Requires cloud permissions (IRSA) tp provision EC2 capacity, plus additiona resources (NodePools/NodeCasses). :contentReference[oaicite:3]{index=3}
**Pros**
- More flexible, often faster scale-up and better packing/cost optimization potential.
- Can choose instance types dynamically and do consolidation.

**Cons**
- More components/config to operate (CRDs, NodePools, NodeClasses).
- More complex IAM surface 
- More tuning needed to keep it safe 
- harder to keep reproducible for an MVP that is frequently destroyed/rebuilt.

---

## Decision

We choose **Cluster Autoscaler** as the node autoscaling solution for ReplicaSafeEKS.

This is because it best satisfies the MVP decision drivers:
- **Lowest complexity** and quickest to working with our existing EKS Managed Node Group setup.
- **Operability** is simpler (fewer concepts and fewer AWS dependencies).
- **IAM blast radius** is smaller than Karpenter’s provisioning model.
- **Demo-ability** is excellent: we can deterministically force Pending pods and observe nodes scale.

Karpenter remains a *future* improvement candidate, but it is explicitly **not part of this iteration**.

---
## Implementation notes 

- Use **IRSA** for the cluster-autoscaler service account.
- Enable **ASG auto-discovery** by taggin the node group ASG(s) with:
    - `k8s.io/cluster-autoscaler/enabled = true`
    - `k8s.io/cluster-autoscaler/<cluster_name> = owned|shared` :contentReference[oaicite:4]{index=4}
- Install CA via Helm (pinned version), and configure:
    - clusterName
    - autodiscovery tags
    - safe scale-down defauts

--

## Demo plan (how we prove it works)

**Goal:** Show scale-up and scale-down on demand, using only kubectl + logs.

### Scale-up proof
1. Ensure node group `max_size >= 2`.
2. Deploy a workload that requests enough CPU/memory to exceed current capacity:
   - Example: 2–5 replicas with requests that exceed remaining allocatable.
3. Observe:
   - Pods go `Pending` with `Unschedulable`
   - CA logs show a scale-up decision
   - New node joins: `kubectl get nodes -w`
   - Pending pods become `Running`

### Scale-down proof
1. Scale the workload down to 0 or 1 replica.
2. Observe:
   - CA marks a node as unneeded
   - Node drains and terminates after the scale-down delay window
   - Node count decreases

Evidence to capture:
- `kubectl get pods -w` (Pending → Running)
- `kubectl get nodes -w` (1 → 2)
- `kubectl -n kube-system logs deploy/cluster-autoscaler --tail=200`

---

## Rollback plan (if this choice sucks)

Rollback is simple because CA does not change core cluster components:
1. Uninstall CA Helm release.
2. Remove CA IRSA IAM role/policy.
3. Remove autoscaler ASG tags.

If CA is insufficient (slow scaling, poor packing, node group constraints), open a new ADR to evaluate Karpenter with:
- strict limits
- disruption/consolidation policy
- spot strategy
- hard guardrails on instance types and costs

---

## Consequences

- We accept that CA is less “smart” than Karpenter in node selection.
- We get a stable, easy-to-operate autoscaling baseline aligned with MNG.
- This unblocks HPA/KEDA work with minimal platform risk.

---

## References
- EKS best practices: Cluster Autoscaler :contentReference[oaicite:5]{index=5}
- EKS best practices: Karpenter :contentReference[oaicite:6]{index=6}
- CA behavior (unschedulable pods trigger scale-up) :contentReference[oaicite:7]{index=7}
- CA AWS provider autodiscovery tags :contentReference[oaicite:8]{index=8}
- Karpenter getting started (IRSA + cloud permissions) :contentReference[oaicite:9]{index=9}