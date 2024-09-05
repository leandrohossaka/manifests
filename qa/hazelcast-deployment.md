
# Deployment do Hazelcast   

Para fazer deployment do hazelcast temos algumas opções, a recomendada pelo site é utilizar o
 [Hazelcast Platform Operator for Kubernetes/OpenShift](https://docs.hazelcast.com/hazelcast/5.4/kubernetes/deploying-in-kubernetes#hazelcast-platform-operator-for-kubernetesopenshift)

## Para isso utilizamos os comandos abaixo

```bash
helm repo add hazelcast https://hazelcast-charts.s3.amazonaws.com/
helm repo update
helm install hz-hazelcast hazelcast/hazelcast

kubectl apply -f hazelcast-deployment.yml -n dott-qa
```



