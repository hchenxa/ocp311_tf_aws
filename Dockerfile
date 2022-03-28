FROM hashicorp/terraform:0.12.31

WORKDIR /opt
COPY ./* /opt/
RUN ssh-keygen -t rsa -b 4096 -f ${HOME}/.ssh/id_rsa -q -N ""
RUN terraform init
ENTRYPOINT sh
