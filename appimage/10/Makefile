MAGIC_SRC_ROOT = ../..
RESOURCES := $(shell find ../rsc/ -type f)
ARCH := $(shell uname -m)
APPIMAGE = Magic-$(ARCH).AppImage
VERSION_MAGIC := $(shell cat $(MAGIC_SRC_ROOT)/VERSION)
VERSION_TSTAMP := $(shell git show -s "--format=%cs" | tr -d '-')
VERSION_HASH := $(shell git show-ref --hash=7 remotes/origin/HEAD)
VERSION_NUM ?= $(VERSION_MAGIC)~$(VERSION_TSTAMP)~$(VERSION_HASH)
VERSION := $(VERSION_NUM)

all: $(APPIMAGE)

.PHONY: prefix/bin/magic
prefix/bin/magic: Dockerfile Makefile
	@echo "APPIMAGE=$(APPIMAGE)"
	@echo "VERSION=$(VERSION)"
	@echo "ARCH=$(ARCH)"
	@echo "RESOURCES=$(RESOURCES)"
	rm -rf prefix
	docker build -t magic_build -f ./Dockerfile $(MAGIC_SRC_ROOT)
	id=$$(docker create magic_build) ; \
	docker cp $$id:/prefix ./prefix ; \
	docker rm -v $$id
	mkdir -p prefix/lib/tcl9.0.1
	cp -r prefix/lib/tcl9.0 prefix/lib/tcl9.0.1/library

appimagetool:
	curl -L https://github.com/AppImage/appimagetool/releases/download/1.9.0/appimagetool-x86_64.AppImage > ./appimagetool
	chmod +x ./appimagetool

$(APPIMAGE): prefix/bin/magic appimagetool $(RESOURCES)
	cp $(RESOURCES) ./prefix/
	./appimagetool prefix

PREFIX ?= /usr/local
install:
	install $(APPIMAGE) $(PREFIX)/bin/magic

.PHONY: clean
clean:
	rm -f *.AppImage
	rm -f prefix.tar.gz
	rm -rf prefix
