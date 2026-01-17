# Demos

## Storage (PVC persistence)
```bash
./bin/rsedp demo-storage
kubectl delete ns demo-storage
````

## ALB Ingress

Prereq: controller installed

```bash
./bin/rsedp alb
./bin/rsedp demo-alb
kubectl delete ns demo-ingress
```

## Cluster Autoscaler

```bash
./bin/rsedp autoscaler
./bin/rsedp demo-autoscaling
kubectl -n kube-system logs deploy/cluster-autoscaler -f --tail=200
kubectl delete deploy cpu-hog
```

## SQS + KEDA

```bash
./bin/rsedp sqs
./bin/rsedp pump-sqs 30
kubectl -n default get deploy sqs-worker -w
kubectl -n keda logs deploy/keda-operator -f --tail=200
```