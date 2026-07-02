# Copyright 2026 Zhone Inc
# vim: ts=4 noet

REGISTRY  ?= rt.cloud.dzsi.local/docker
IMAGE     := rw.kubectl
TAG       ?= 1.0
FULL_NAME  = $(REGISTRY)/$(IMAGE):$(TAG)

KUBECTL_VERSION ?= 1.36.2

.PHONY: all build push

all: build push

build:
	docker build --pull --build-arg KUBECTL_VERSION=$(KUBECTL_VERSION) -t $(FULL_NAME) $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

push:
	docker push $(FULL_NAME)
