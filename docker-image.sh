#!/bin/bash

set -x
echo "{\"insecure-registries\":[\"${bastion_ip}:5000\"]}" > /home/ec2-user/docker-daemon.json

sudo cp /home/ec2-user/docker-daemon.json /etc/docker/daemon.json

sudo systemctl daemon-reload
sudo systemctl restart docker

sudo mkdir -p /root/.docker
echo ${ocp_image_pull_secret} > /home/ec2-user/image_pull_secret 
sudo cp /home/ec2-user/image_pull_secret /root/.docker/config.json

sudo docker run -d --net=host --restart=always --name registry registry:2
package_version=$(sudo yum info atomic-openshift-node.x86_64 | grep Version| awk -F ':' '{print $2}')

images="openshift3/apb-base 
openshift3/apb-tools 
openshift3/automation-broker-apb 
openshift3/csi-attacher 
openshift3/csi-driver-registrar 
openshift3/csi-livenessprobe 
openshift3/csi-provisioner 
openshift3/grafana 
openshift3/kuryr-controller 
openshift3/kuryr-cni 
openshift3/local-storage-provisioner 
openshift3/manila-provisioner 
openshift3/mariadb-apb 
openshift3/mediawiki 
openshift3/mediawiki-apb 
openshift3/mysql-apb 
openshift3/ose-ansible-service-broker 
openshift3/ose-cli 
openshift3/ose-cluster-autoscaler 
openshift3/ose-cluster-capacity 
openshift3/ose-cluster-monitoring-operator 
openshift3/ose-console 
openshift3/ose-configmap-reloader 
openshift3/ose-control-plane 
openshift3/ose-deployer 
openshift3/ose-descheduler 
openshift3/ose-docker-builder 
openshift3/ose-docker-registry 
openshift3/ose-efs-provisioner 
openshift3/ose-egress-dns-proxy 
openshift3/ose-egress-http-proxy 
openshift3/ose-egress-router 
openshift3/ose-haproxy-router 
openshift3/ose-hyperkube 
openshift3/ose-hypershift 
openshift3/ose-keepalived-ipfailover 
openshift3/ose-kube-rbac-proxy 
openshift3/ose-kube-state-metrics 
openshift3/ose-metrics-server 
openshift3/ose-node 
openshift3/ose-node-problem-detector 
openshift3/ose-operator-lifecycle-manager 
openshift3/ose-ovn-kubernetes 
openshift3/ose-pod 
openshift3/ose-prometheus-config-reloader 
openshift3/ose-prometheus-operator 
openshift3/ose-recycler 
openshift3/ose-service-catalog 
openshift3/ose-template-service-broker 
openshift3/ose-tests 
openshift3/ose-web-console 
openshift3/postgresql-apb 
openshift3/registry-console 
openshift3/snapshot-controller 
openshift3/snapshot-provisioner
openshift3/oauth-proxy
openshift3/prometheus
openshift3/prometheus-alertmanager
openshift3/prometheus-node-exporter"

for image in $images
do
    sudo docker pull registry.redhat.io/$image:v$package_version
    sudo docker tag registry.redhat.io/$image:v$package_version ${bastion_ip}:5000/$image:v$package_version
    sudo docker tag registry.redhat.io/$image:v$package_version ${bastion_ip}:5000/$image:v3.11
    sudo docker push ${bastion_ip}:5000/$image:v$package_version
    sudo docker push ${bastion_ip}:5000/$image:v3.11
done

sudo docker pull registry.redhat.io/rhel7/etcd:3.2.32
sudo docker tag registry.redhat.io/rhel7/etcd:3.2.32 ${bastion_ip}:5000/rhel7/etcd:3.2.32
sudo docker push ${bastion_ip}:5000/rhel7/etcd:3.2.32