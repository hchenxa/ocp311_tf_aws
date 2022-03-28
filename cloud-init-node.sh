#! /bin/bash

# Update node
rm -rf /etc/yum.repos.d/*

echo "
[rhel-7-server-rpms]
name=rhel-7-server-rpms
baseurl=http://${bastion_ip}/repos/rhel-7-server-rpms 
enabled=1
gpgcheck=0
[rhel-7-server-extras-rpms]
name=rhel-7-server-extras-rpms
baseurl=http://${bastion_ip}/repos/rhel-7-server-extras-rpms 
enabled=1
gpgcheck=0
[rhel-7-server-ansible-2.9-rpms]
name=rhel-7-server-ansible-2.9-rpms
baseurl=http://${bastion_ip}/repos/rhel-7-server-ansible-2.9-rpms 
enabled=1
gpgcheck=0
[rhel-7-server-ose-3.11-rpms]
name=rhel-7-server-ose-3.11-rpms
baseurl=http://${bastion_ip}/repos/rhel-7-server-ose-3.11-rpms 
enabled=1
gpgcheck=0
" > /etc/yum.repos.d/${bastion_ip}.repo

# Signal to Terraform that update is complete and reboot
touch /home/ec2-user/cloud-init-complete

if [ `cat /etc/hosts | grep -i ${master_ip} | wc -l` != 0]; then
    echo ${master_ip} ${master_hostname} >> /etc/hosts
fi
# Signal to Terraform to skip the OCP install steps (prerequisites and deploy_cluster)
${skip_install ? "" : "#"}touch /home/ec2-user/ocp-prereq-complete
${skip_install ? "" : "#"}touch /home/ec2-user/ocp-install-complete
reboot
