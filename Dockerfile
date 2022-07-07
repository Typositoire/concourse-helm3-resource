FROM alpine/helm:3.8.0
LABEL maintainer "Yann David (@Typositoire) <davidyann88@gmail>"

#Versions for gcloud,kubectl,doctl
ARG KUBERNETES_VERSION=1.21.5
ARG GCLOUD_VERSION=327.0.0
ARG DOCTL_VERSION=1.57.0
ARG HELM_PLUGINS_TO_INSTALL="https://github.com/databus23/helm-diff"

#gcloud path
ENV PATH $PATH:/usr/local/gcloud/google-cloud-sdk/bin

#install packages
RUN apk add --update --upgrade --no-cache jq bash curl git gettext libintl py-pip

#install kubectl
RUN curl -sL -o /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl; \
    chmod +x /usr/local/bin/kubectl

#install gcloud
RUN wget https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${GCLOUD_VERSION}-linux-x86_64.tar.gz \
    -O /tmp/google-cloud-sdk.tar.gz | bash

RUN mkdir -p /usr/local/gcloud \
    && tar -C /usr/local/gcloud -xvzf /tmp/google-cloud-sdk.tar.gz \
    && /usr/local/gcloud/google-cloud-sdk/install.sh -q

#copy scripts
ADD assets /opt/resource

#install plugins
RUN for i in $(echo $HELM_PLUGINS_TO_INSTALL | xargs -n1); do helm plugin install $i; done

#install kustomize
RUN curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash && \
  install kustomize /usr/local/bin/kustomize

#install doctl
RUN curl -sL -o /tmp/doctl.tar.gz https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz && \
  tar -C /usr/local/bin -zxvf /tmp/doctl.tar.gz && \
  chmod +x /usr/local/bin/doctl

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]
