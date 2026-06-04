# Copyright 2025 Zhone Inc
# vim: ts=4 noet

REGISTRY  ?= rt.cloud.dzsi.local/docker
IMAGE     := rw.sftp
TAG       ?= 1.0
FULL_NAME  = $(REGISTRY)/$(IMAGE):$(TAG)

.PHONY: all build push

all: build push

build:
	docker build --pull -t $(FULL_NAME) $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

push:
	docker push $(FULL_NAME)
