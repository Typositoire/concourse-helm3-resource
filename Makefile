PROJECT = concourse-helm3
ID = artielabs/${PROJECT}

all: build push

build:
	docker build --tag ${ID}:release-candidate .

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
