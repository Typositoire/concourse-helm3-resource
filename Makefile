PROJECT = devops/concourse-helm-3
ID = registry.infra.yoti.com/${PROJECT}

all: build push

build:
	docker build --tag ${ID} .

push:
	docker push ${ID}

run:
	docker run \
		--volume $(shell pwd):/opt/helm-3 \
		--workdir /opt/helm-3 \
		--interactive \
		--tty \
		${ID}:latest \
		bash
