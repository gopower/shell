#!/bin/bash
# kind install

# curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.11.1/kind-linux-amd64
curl -Lo ./kind https://hub.fastgit.org/kubernetes-sigs/kind/releases/download/v0.11.1/kind-linux-amd64
chmod +x ./kind
mv ./kind /usr/local/bin/kind

sudo yum install -y yum-utils
# Step 2: 添加软件源信息
sudo yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
# Step 3
sudo sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+' /etc/yum.repos.d/docker-ce.repo
# Step 4: 更新并安装Docker-CE
sudo yum makecache fast
sudo yum -y install docker-ce
# Step 4: 开启Docker服务
sudo systemctl start docker && sudo systemctl enable docker

cat <<EOF >/etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
yum install -y kubectl

docker pull kindest/node:v1.23.0@sha256:49824ab1727c04e56a21a5d8372a402fcd32ea51ac96a2706a12af38934f81ac

cat >./kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.23.0@sha256:49824ab1727c04e56a21a5d8372a402fcd32ea51ac96a2706a12af38934f81ac
- role: worker
  image: kindest/node:v1.23.0@sha256:49824ab1727c04e56a21a5d8372a402fcd32ea51ac96a2706a12af38934f81ac
- role: worker
  image: kindest/node:v1.23.0@sha256:49824ab1727c04e56a21a5d8372a402fcd32ea51ac96a2706a12af38934f81ac
- role: worker
  image: kindest/node:v1.23.0@sha256:49824ab1727c04e56a21a5d8372a402fcd32ea51ac96a2706a12af38934f81ac
networking:
  disableDefaultCNI: true
EOF

kind create cluster --config=kind-config.yaml

curl -L --remote-name-all https://download.fastgit.org/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz\{,.sha256sum\}
tar -zxvf cilium-linux-amd64.tar.gz

cilium install --version -service-mesh:v1.11.0-beta.1 --config enable-envoy-config=true --kube-proxy-replacement=probe --agent-image='quay.io/cilium/cilium-service-mesh:v1.11.0-beta.1' --operator-image='quay.io/cilium/operator-generic-service-mesh:v1.11.0-beta.1' --datapath-mode=vxlan

cilium hubble enable --relay-image='quay.io/cilium/hubble-relay-service-mesh:v1.11.0-beta.1' --ui

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/namespace.yaml

kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/metallb.yaml

docker network inspect -f '{{.IPAM.Config}}' kind

# vim kind-lb-cm.yaml
cat >kind-lb-cm.yaml <<-EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 172.18.255.200-172.18.255.250
EOF
kubectl apply -f kind-lb-cm.yaml

docker pull hashicorp/http-echo:0.2.3
kind load docker-image hashicorp/http-echo:0.2.3

cat >app.yaml <<-EOF
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: foo-app
  name: foo-app
spec:
  containers:
  - image: hashicorp/http-echo:0.2.3
    args:
    - "-text=foo"
    name: foo-app
    ports:
    - containerPort: 5678
    resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Always
status: {}
---
apiVersion: v1
kind: Service
metadata:
  labels:
    run: foo-app
  name: foo-app
spec:
  ports:
  - port: 5678
    protocol: TCP
    targetPort: 5678
  selector:
    run: foo-app
---
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: bar-app
  name: bar-app
spec:
  containers:
  - image: hashicorp/http-echo:0.2.3
    args:
    - "-text=bar"
    name: bar-app
    ports:
    - containerPort: 5678
    resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Always
---
apiVersion: v1
kind: Service
metadata:
  labels:
    run: bar-app
  name: bar-app
spec:
  ports:
  - port: 5678
    protocol: TCP
    targetPort: 5678
  selector:
    run: bar-app
EOF

cat >cilium-ingress.yaml <<-EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cilium-ingress
  namespace: default
spec:
  ingressClassName: cilium
  rules:
  - http:
      paths:
      - backend:
          service:
            name: foo-app
            port:
              number: 5678
        path: /foo
        pathType: Prefix
      - backend:
          service:
            name: bar-app
            port:
              number: 5678
        path: /bar
        pathType: Prefix
EOF

kubectl apply -f cilium-ingress.yaml

kubectl get svc
kubectl get ing
