kubectl create ns demo-storage

cat <<'YAML' | kubectl -n demo-storage apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: gp3-csi
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: writer
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh","-c","echo hello-$(date) >> /data/out.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: demo-pvc
YAML

kubectl -n demo-storage get pvc,pod
kubectl -n demo-storage exec writer -- tail -n 5 /data/out.txt

# Prove persistence:
kubectl -n demo-storage delete pod writer
kubectl -n demo-storage apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: reader
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh","-c","tail -n 20 /data/out.txt; sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: demo-pvc
YAML

kubectl -n demo-storage logs reader