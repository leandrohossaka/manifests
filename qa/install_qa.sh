helm repo add hazelcast https://hazelcast-charts.s3.amazonaws.com/
helm repo update
helm install hz-hazelcast hazelcast/hazelcast -n dott-qa

kubectl apply -f backendconfig.yml -n dott-qa
kubectl apply -f cluster-role-binding.yml -n dott-qa
kubectl apply -f managed-cert.yml -n dott-qa

kubectl apply -f mysql-storage.yml -n dott-qa
kubectl apply -f mysql-secret.yml -n dott-qa
kubectl apply -f mysql-deployment.yml -n dott-qa
kubectl apply -f nfs-server.yml -n dott-qa
kubectl apply -f ssl-redirect.yml -n dott-qa
kubectl apply -f nfs-pv-dott.yml -n dott-qa
kubectl apply -f nfs-pv.yml -n dott-qa
kubectl apply -f nfs-pvc-dott.yml -n dott-qa
kubectl apply -f nfs-pvc.yml -n dott-qa
kubectl apply -f ingress-front.yml -n dott-qa
