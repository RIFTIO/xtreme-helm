# Copyright 2025 Zhone Inc
# vim: ts=4 noet
#
# Top-level Makefile for all custom container images under this directory.
# Delegates to each subdirectory that contains its own Makefile.
#
# Usage:
#   make              # build + push all images
#   make build        # build all images (no push)
#   make push         # push all images (assumes already built)
#   make REGISTRY=my.registry.local all
#   make TAG=dev build   # override tag for all images
#
# To operate on a single image:
#   make -C vsftpd
#   make -C vsftpd build

SUBDIRS := $(patsubst %/Makefile,%,$(wildcard */Makefile))

export REGISTRY
export TAG

.PHONY: all build push $(SUBDIRS)

all: $(addprefix all-,$(SUBDIRS))
build: $(addprefix build-,$(SUBDIRS))
push: $(addprefix push-,$(SUBDIRS))

all-%:
	$(MAKE) -C $* all

build-%:
	$(MAKE) -C $* build

push-%:
	$(MAKE) -C $* push
