# Cordon and drain
Mark node unschedulable then evict pods.
```bash
# cordon first
kubectl cordon node1
kubectl drain node1 \
  --ignore-daemonsets
```
```console
$ kubectl get nodes
NAME STATUS
node1 Ready
```
```yaml
apiVersion: v1
```
