# Set the cloud provider to AWS
provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
#   CLUSTER/INSTANCE INFO   #
#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Create local variables for tags and cluster ID
locals {
  cluster_id = "${var.cluster_user_id}-${var.cluster_name}"
  common_tags = map(
    "Cluster", local.cluster_id,
    "kubernetes.io/cluster/${local.cluster_id}", "owned"
  )
  cluster_domain        = "${local.cluster_id}.${var.aws_base_dns_domain}"
  cluster_master_domain = "master.${local.cluster_domain}"
  cluster_subdomain     = "apps.${local.cluster_domain}"
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
#    OCP INVENTORY FILE     #
#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Render OCP inventory file from cluster information
data "template_file" "inventory" {
  template = file("./inventory.template")
  vars = {
    cluster_id                = local.cluster_id
    ocp_user                  = var.ocp_user
    ocp_pass                  = var.ocp_pass
    aws_access_key_id         = var.aws_access_key_id
    aws_secret_access_key     = var.aws_secret_access_key
    openshift_deployment_type = var.openshift_deployment_type
    rh_subscription_username  = var.rh_subscription_username
    rh_subscription_password  = var.rh_subscription_password
    public_hostname           = local.cluster_master_domain
    public_subdomain          = local.cluster_subdomain
    bastion_ip                = aws_instance.bastion.private_ip
    master_hostname           = aws_instance.master.private_dns
    node_hostname             = aws_instance.node.private_dns
  }
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
#       SSH KEY PAIR        #
#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Set up a key pair for SSH access to instances
resource "aws_key_pair" "default" {
  key_name   = "${local.cluster_id}_ssh_key"
  public_key = file(var.ssh_public_key_path)
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
#   INSTANCE INITIALIZATION SCRIPT   #
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Cloud-Init script to register and update bastion
data "template_file" "cloud-init-bastion" {
  template = file("./cloud-init-bastion.sh")
  vars = {
    openshift_deployment_type = var.openshift_deployment_type
    rh_subscription_username  = var.rh_subscription_username
    rh_subscription_password  = var.rh_subscription_password
    rh_subscription_pool_id   = var.rh_subscription_pool_id
    skip_install              = var.skip_install
  }
}

# Cloud-Init script to register and update nodes
data "template_file" "cloud-init-master" {
  template = file("./cloud-init-master.sh")
  vars = {
    bastion_ip = aws_instance.bastion.private_ip
    skip_install              = var.skip_install
  }
}

# Cloud-Init script to register and update nodes
data "template_file" "cloud-init-node" {
  template = file("./cloud-init-node.sh")
  vars = {
    bastion_ip = aws_instance.bastion.private_ip
    master_ip = aws_instance.master.private_ip
    master_hostname = aws_instance.master.private_dns
    skip_install              = var.skip_install
  }
}

# render the docker-images
data "template_file" "ocp311-docker-image" {
  template = file("./docker-image.sh")
  vars = {
    image_version = var.ocp_image_tag
    bastion_ip = aws_instance.bastion.private_ip
    ocp_image_pull_secret = var.ocp_pull_secret
  }
}


#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
#        INSTALL OCP        #
#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Install OCP after Bastion reboot
resource "null_resource" "ocp_install" {
  connection {
    type        = "ssh"
    host        = aws_instance.bastion.public_dns
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  # Check for cloud-init file to be created (right before reboot)
  provisioner "remote-exec" {
    inline = [
      "while [ ! -f /home/ec2-user/cloud-init-complete ]; do echo WAITING FOR NODES TO UPDATE...; sleep 30; done"
    ]
    on_failure = continue
  }

  # Wait for reboot via SSH check (max 10 retries)
  provisioner "local-exec" {
    command = "echo === WAITING FOR HOST REBOOT...; count=10; while ! $(ssh -o StrictHostKeyChecking=no -i ${var.ssh_private_key_path} ec2-user@${aws_instance.bastion.public_dns} exit); do sleep 15; if [ $count -eq 0 ]; then exit 1; fi; echo RETRYING...$((count-=1)) tries remaining...; done"
  }

  # Prepare the Bastion host
  provisioner "remote-exec" {
    inline = [
      "echo === INSTALLING THE REQUIRED PACAKGE",
      "chmod 0600 /home/ec2-user/.ssh/id_rsa",
      "sudo yum install -y yum-utils createrepo docker git httpd squid"
    ]
  }

  # Prepare and populate the repository server
  provisioner "remote-exec" {
    inline = [
      "echo === PREPARE AND POPOLATE THE REPOSITORY SERVER",
      "sudo mkdir -p /var/www/html/repos",
      "sudo reposync --gpgcheck -lm --repoid=rhel-7-server-rpms --download_path=/var/www/html/repos",
      "sudo createrepo -v /var/www/html/repos/rhel-7-server-rpms -o /var/www/html/repos/rhel-7-server-rpms",
      "sudo reposync --gpgcheck -lm --repoid=rhel-7-server-extras-rpms --download_path=/var/www/html/repos",
      "sudo createrepo -v /var/www/html/repos/rhel-7-server-extras-rpms -o /var/www/html/repos/rhel-7-server-extras-rpms",
      "sudo reposync --gpgcheck -lm --repoid=rhel-7-server-ansible-2.9-rpms --download_path=/var/www/html/repos",
      "sudo createrepo -v /var/www/html/repos/rhel-7-server-ansible-2.9-rpms -o /var/www/html/repos/rhel-7-server-ansible-2.9-rpms",
      "sudo reposync --gpgcheck -lm --repoid=rhel-7-server-ose-3.11-rpms --download_path=/var/www/html/repos",
      "sudo createrepo -v /var/www/html/repos/rhel-7-server-ose-3.11-rpms -o /var/www/html/repos/rhel-7-server-ose-3.11-rpms",
      "sudo chmod -R +r /var/www/html/repos; sudo restorecon -vR /var/www/html",
      "sudo systemctl enable httpd; sudo systemctl start httpd"
    ]
  }

  # Pull Docker images
  provisioner "remote-exec" {
    inline = [
      "echo === START TO PULL OCP311 IMAGES",
      "echo ${data.template_file.ocp311-docker-image.rendered} > /tmp/ocp311-docker-image.sh",
      "sudo chmod a+x /tmp/ocp311-docker-image.sh"
    ]
  }
  provisioner "remote-exec" {
    inline = [
      "echo === EXECUTE THE SCRIPTS",
      "bash -x /tmp/ocp311-docker-image.sh"
    ]
  }
  # Prepare the inventory file
  provisioner "file" {
    content     = data.template_file.inventory.rendered
    destination = "~/inventory.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "echo === PREPPING BASTION FOR OCP INSTALL...",
      "chmod 0600 /home/ec2-user/.ssh/id_rsa",
      "sudo yum install -y \"@Development Tools\" ansible python27-python-pip pyOpenSSL python-cryptography python-lxml",
      "if ! ls -d openshift-ansible &>/dev/null; then git clone -b release-3.11 https://github.com/openshift/openshift-ansible; else echo === openshift-ansible directory already exists...; fi"
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "echo === INSTALLING OCP PREREQUISITES...",
      "cd /home/ec2-user/openshift-ansible",
      "if [ ! -f /home/ec2-user/ocp-prereq-complete ]; then ansible-playbook -i /home/ec2-user/inventory.yaml playbooks/prerequisites.yml; else echo === prerequisite playbook already run...; fi"
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "echo === INSTALLING OCP...",
      "if [ ! -f /home/ec2-user/ocp-prereq-complete ]; then touch /home/ec2-user/ocp-prereq-complete; fi",
      "cd /home/ec2-user/openshift-ansible",
      "if [ ! -f /home/ec2-user/ocp-install-complete ]; then ansible-playbook -i /home/ec2-user/inventory.yaml playbooks/deploy_cluster.yml; else echo === install playbook already run...; fi"
    ]
  }

  # Establish our user
  provisioner "remote-exec" {
    inline = [
      "echo === ESTABLISHING USER...",
      "if [ ! -f /home/ec2-user/ocp-install-complete ]; then ssh -o StrictHostKeyChecking=no ${aws_instance.master.private_dns} sudo htpasswd -b /etc/origin/master/htpasswd ${var.ocp_user} ${var.ocp_pass}; else echo === user already established...; fi",
      "if [ ! -f /home/ec2-user/ocp-install-complete ]; then ssh -o StrictHostKeyChecking=no ${aws_instance.master.private_dns} oc adm policy add-cluster-role-to-user cluster-admin ${var.ocp_user}; fi"
    ]
  }

  # Signal completion
  provisioner "remote-exec" {
    inline = [
      "if [ ! -f /home/ec2-user/ocp-install-complete ]; then touch /home/ec2-user/ocp-install-complete; fi"
    ]
  }
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
#   INSTANCE DESTROY SCRIPTS  #
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Unregister nodes on destroy
resource "null_resource" "unregister_master" {
  depends_on = [
    null_resource.unregister_bastion
  ]
  triggers = {
    ssh_key    = file(var.ssh_private_key_path)
    bastion_ip = aws_instance.bastion.public_ip
    master_ip  = aws_instance.master.private_ip
  }

  connection {
    type         = "ssh"
    host         = self.triggers.master_ip
    user         = "ec2-user"
    bastion_host = self.triggers.bastion_ip
    private_key  = self.triggers.ssh_key
  }

  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    inline = [
      "sudo subscription-manager remove --all",
      "sudo subscription-manager unregister"
    ]
  }
}
resource "null_resource" "unregister_node" {
  depends_on = [
    null_resource.unregister_bastion
  ]
  triggers = {
    ssh_key    = file(var.ssh_private_key_path)
    bastion_ip = aws_instance.bastion.public_ip
    node_ip    = aws_instance.node.private_ip
  }

  connection {
    type         = "ssh"
    host         = self.triggers.node_ip
    user         = "ec2-user"
    bastion_host = self.triggers.bastion_ip
    private_key  = self.triggers.ssh_key
  }

  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    inline = [
      "sudo subscription-manager remove --all",
      "sudo subscription-manager unregister"
    ]
  }
}
resource "null_resource" "unregister_bastion" {
  depends_on = [
    aws_nat_gateway.private_natgateway,
    aws_route_table_association.public-subnet,
    aws_route_table_association.private-subnet,
    aws_iam_policy_attachment.ocp311_attach_master_policy,
    aws_iam_policy_attachment.ocp311_attach_worker_policy
  ]
  triggers = {
    ssh_key    = file(var.ssh_private_key_path)
    bastion_ip = aws_instance.bastion.public_ip
  }

  connection {
    type        = "ssh"
    host        = self.triggers.bastion_ip
    user        = "ec2-user"
    private_key = self.triggers.ssh_key
  }

  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    inline = [
      "sudo subscription-manager remove --all",
      "sudo subscription-manager unregister"
    ]
  }
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
#          OUTPUT           #
#~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Output cluster access commands/addresses
output "bastion_ssh" {
  value       = "ssh -i ${var.ssh_private_key_path} ec2-user@${aws_instance.bastion.public_dns}"
  description = "Public IP of Bastion (for SSH access)"
}
output "cluster_console_url" {
  value       = "https://master.${local.cluster_domain}:8443"
  description = "Console address using Public IP of Master"
}
output "cluster_cli_login" {
  value       = "oc login https://master.${local.cluster_domain}:8443 -u ${var.ocp_user} -p ${var.ocp_pass} --insecure-skip-tls-verify"
  description = "Command to log in to cluster"
}
output "private_dns_master" {
  value       = aws_instance.master.private_dns
  description = "Private DNS of Master Node (to SSH from Bastion)"
}
output "private_dns_node" {
  value       = aws_instance.node.private_dns
  description = "Private DNS of Compute Node (to SSH from Bastion)"
}
