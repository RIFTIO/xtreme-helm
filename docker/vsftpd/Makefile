# Copyright 2025 Zhone Inc
# vim: ts=4 noet

REGISTRY  ?= rt.cloud.dzsi.local/docker
IMAGE     := rw.vsftpd
TAG       ?= 1.2
FULL_NAME  = $(REGISTRY)/$(IMAGE):$(TAG)

.PHONY: all build push

all: build push

build:
	docker build --pull -t $(FULL_NAME) $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

push:
	docker push $(FULL_NAME)
