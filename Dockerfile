FROM ubuntu:24.04

ARG RUNNER_VERSION="2.322.0"
SHELL ["/bin/bash", "-c"]
USER root

ARG DEBIAN_FRONTEND=noninteractive

RUN apt update -y \
    && apt install -y --no-install-recommends sudo lsb-release software-properties-common gpg-agent curl jq unzip \
    && add-apt-repository ppa:git-core/ppa \
    && apt update -y \
    && apt install -y --no-install-recommends git \
    && apt upgrade -y  \
    && apt install -y --no-install-recommends \
    build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip vim dumb-init ca-certificates \
    && mkdir /runner && cd /runner && \
    curl -o actions-runner-linux.tar.gz -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz && \
    tar xzf ./actions-runner-linux.tar.gz && \
    rm ./actions-runner-linux.tar.gz && \
    ./bin/installdependencies.sh

# dependencies
## docker
RUN groupadd docker && useradd -m docker -g docker -u 1002 && \
    useradd -m runner -g docker -u 1001
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
     echo \
       "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
       $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
       tee /etc/apt/sources.list.d/docker.list > /dev/null && \
     apt-get update && \
     sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

## build
RUN apt-get update && apt-get -y upgrade && \
  apt-get -y install gpg zip bzip2 apt-transport-https gnupg zstd ca-certificates

## github ssh key
RUN mkdir /home/runner/.ssh/ && \
  chown runner: /home/runner/.ssh/ && \
  chmod 0700 /home/runner/.ssh/ && \
  ssh-keyscan github.com | tee -a /home/runner/.ssh/known_hosts

RUN mkdir /opt/runner && chmod 777 /runner /opt/runner
RUN echo "runner   ALL=(ALL) NOPASSWD: /usr/bin/dockerd,/usr/bin/pkill" >> /etc/sudoers && \
    echo "runner   ALL=(ALL) NOPASSWD: /usr/bin/rm /var/run/docker.pid" >> /etc/sudoers && \
    echo "runner   ALL=(ALL) NOPASSWD: /usr/sbin/update-ca-certificates" >> /etc/sudoers && \
    echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" >> /etc/sudoers

ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
RUN mkdir /opt/hostedtoolcache \
    && chgrp docker /opt/hostedtoolcache \
    && chmod g+rwx /opt/hostedtoolcache

RUN touch /usr/local/share/ca-certificates/cache-server-ca.crt \
    && chmod 777 /usr/local/share/ca-certificates/cache-server-ca.crt
COPY --chmod=0555 files/start.sh /opt/runner/
RUN chown runner /opt/runner/ &&\
    chown -R runner /runner/

USER runner

ENTRYPOINT ["/bin/bash", "-c"]
CMD ["/opt/runner/start.sh"]
