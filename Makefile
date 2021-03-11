PREFIX ?= $(if $(VIRTUAL_ENV),$(VIRTUAL_ENV),$(if $(CONDA_PREFIX),$(CONDA_PREFIX),$(PWD)/local))

BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
INCDIR = $(PREFIX)/include
SHAREDIR = $(PREFIX)/share/ocrd_olena

PYTHON ?= $(shell which python3)
PIP ?= $(shell which pip3)

export IMAGEMAGICKXX_CFLAGS ?= $(shell pkg-config --cflags Magick++)
export IMAGEMAGICKXX_LIBS ?= $(shell pkg-config --libs Magick++)

DOCKER_TAG ?= ocrd/olena
TOOLS = ocrd-olena-binarize

# BEGIN-EVAL makefile-parser --make-help Makefile

help:
	@echo ""
	@echo "  Targets"
	@echo ""
	@echo "    deps-ubuntu      Install dependencies in system (apt)"
	@echo "    deps-conda       Install dependencies in current conda env"
	@echo "    build            Build included dependencies"
	@echo "    clean            Clean builds of included dependencies"
	@echo "    build-conda      Build included deps for conda installation"
	@echo "    clean-conda      Clean builds for conda installation"
	@echo "    install          Install binaries into PATH"
	@echo "    uninstall        Uninstall binaries and assets"
	@echo "    install-conda    Install binaries into conda environment"
	@echo "    uninstall-conda  Uninstall binaries and assets from conda env"
	@echo "    repo/assets      Clone OCR-D/assets to ./repo/assets"
	@echo "    assets           Setup test assets"
	@echo "    test             Run basic tests"
	@echo "    docker           Build docker images"
	@echo ""
	@echo "  Variables"
	@echo ""
	@echo "    PREFIX           Directory to install to ('$(PREFIX)')"
	@echo "    PYTHON           Python binary to bind to ('$(PYTHON)')"
	@echo "    PIP              Python pip to install with ('$(PIP)')"

.PHONY: help

# END-EVAL

#
# Assets
#

# Ensure assets and olena git repos are always on the correct revision:
.PHONY: assets-update

# Checkout OCR-D/assets submodule to ./repo/assets
repo/assets: assets-update
	git submodule sync "$@"
	git submodule update --init "$@"

# to upgrade, use `git -C repo/assets pull` and commit ...

# Copy index of assets
test/assets: repo/assets
	mkdir -p $@
	git -C repo/assets checkout-index -a -f --prefix=$(abspath $@)/

# Run tests
test: test/assets
	cd test && PATH=$(BINDIR):$$PATH bash test.sh

#
# Dependency installation
#

deps-ubuntu:
	apt-get -y install \
		git g++ make automake \
		xmlstarlet ca-certificates libmagick++-6.q16-dev \
		libgraphicsmagick++1-dev libboost-dev

deps-conda:
	conda install -c conda-forge \
		gcc_linux-64 gxx_linux-64 make autoconf pkg-config git \
		ca-certificates boost-cpp imagemagick graphicsmagick libxml2 libxslt \
		libiconv

	# Shortcut to installed compilers:
	-ln -s $(BINDIR)/x86_64-conda_cos6-linux-gnu-gcc $(BINDIR)/gcc
	-ln -s $(BINDIR)/x86_64-conda_cos6-linux-gnu-g++ $(BINDIR)/g++

deps-pip:
	$(PIP) install -U pip
	$(PIP) install "ocrd>=2.13" # needed for ocrd CLI (and bashlib)

.PHONY: deps-ubuntu deps-conda deps

#
# Dependency check
#

check_pkg_config = \
	if ! pkg-config --modversion $(1) >/dev/null 2>/dev/null;then\
		echo "$(1) not installed. 'make deps-ubuntu' or \
			'sudo apt install $(2)' for system-wide (apt) installation or \
			'make deps-conda' or 'conda install -c conda-forge $(3)' for \
			conda env installation"; exit 1 ;\
	fi

check_config_status = \
	if test "$(3)" = "alternative";then predicate='["HAVE_$(1)_TRUE"]="\#"' ;\
	else predicate='["HAVE_$(1)"]=" 1"'; fi;\
	if ! grep -Fq "$$predicate" $(BUILD_DIR)/config.status;then \
		echo "$(2) not installed. 'make deps-ubuntu' or 'sudo apt install $(2)'"; \
		exit 1 ; \
	fi;

deps-olena:
	$(call check_pkg_config,Magick++,libmagick++-6.q16-dev,imagemagick)
	$(call check_pkg_config,GraphicsMagick++,libgraphicsmagick++1-dev,graphicsmagick)
	#$(call check_config_status,BOOST,libboost-dev)

deps-xmlstarlet:
	$(call check_pkg_config,libxml-2.0,,libxml2)
	$(call check_pkg_config,libxslt,,libxslt)
	#$(call check_pkg_config,libiconv,,libiconv)

.PHONY: deps-olena deps-xmlstarlet

#
# Builds
#

OLENA_DIR = $(CURDIR)/repo/olena
OLENA_BUILD = $(OLENA_DIR)/build

$(OLENA_DIR)/configure: assets-update
	git submodule sync "$(OLENA_DIR)"
	git submodule update --init "$(OLENA_DIR)"
	cd "$(OLENA_DIR)" && autoreconf -i

# Build olena with scribo (document analysis) and swilena (Python bindings)
# but without tools/apps and without generating documentation.
# Furthermore, futurize (Py2/3-port) Python code if possible.
# Note that olena fails to configure the dependency tracking, so disable it.
# Note that olena fails to compile scribo with recent compilers
# which abort with an error unless SCRIBO_NDEBUG is defined.
CWD = $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
$(OLENA_BUILD)/config.status: $(OLENA_DIR)/configure
	mkdir -p $(OLENA_BUILD) && \
		cd $(OLENA_BUILD) && \
		$(OLENA_DIR)/configure \
			--prefix=$(PREFIX) \
			--with-boost=$(PREFIX) \
			--with-imagemagickxx=$(PREFIX) \
			--with-graphicsmagickxx=$(PREFIX) \
			--disable-doc \
			--disable-dependency-tracking \
			--with-qt=no \
			--with-tesseract=no \
			--enable-scribo SCRIBO_CXXFLAGS="-DNDEBUG -DSCRIBO_NDEBUG -O2"

build-olena: $(OLENA_BUILD)/config.status deps-olena
	cd $(OLENA_DIR)/milena/mln && touch -r version.hh.in version.hh
	$(MAKE) -C $(OLENA_BUILD)

clean-olena:
	-$(RM) -r $(OLENA_BUILD)

XMLSTARLET_DIR = $(CURDIR)/repo/xmlstarlet
XMLSTARLET_BUILD = $(XMLSTARLET_DIR)

$(XMLSTARLET_DIR):
	git submodule sync "$(XMLSTARLET_DIR)"
	git submodule update --init "$(XMLSTARLET_DIR)"

$(XMLSTARLET_DIR)/configure: $(XMLSTARLET_DIR)
	git submodule sync "$(XMLSTARLET_DIR)"
	git submodule update --init "$(XMLSTARLET_DIR)"
	cd "$(XMLSTARLET_DIR)" && autoreconf -sif

$(XMLSTARLET_BUILD)/config.status: $(XMLSTARLET_DIR)/configure
	mkdir -p $(XMLSTARLET_BUILD) && \
		cd $(XMLSTARLET_BUILD) && \
			$(XMLSTARLET_DIR)/configure \
				--prefix=$(PREFIX) \
				--with-libxml-prefix=$(PREFIX) \
				--with-libxml-include-prefix=$(INCDIR)/libxml2 \
				--with-libxslt-prefix=$(PREFIX) \
				--with-libiconv-prefix=$(PREFIX)

build-xmlstarlet: $(XMLSTARLET_BUILD)/config.status deps-xmlstarlet
	$(MAKE) -C $(XMLSTARLET_BUILD)

clean-xmlstarlet:
	$(MAKE) -C $(XMLSTARLET_BUILD) clean

build: build-olena

clean: clean-olena
	-$(RM) -r test/assets

build-conda: build-xmlstarlet build

clean-conda: clean-xmlstarlet clean

.PHONY: build-olena clean-olena build-xmlstarlet clean-xmlstarlet build \
		clean build-conda clean-conda

#
# Installation
#

install-olena:
	$(MAKE) -C $(OLENA_BUILD) install

uninstall-olena:
	-$(MAKE) -C $(OLENA_BUILD) uninstall

install-xmlstarlet:
	$(MAKE) -C $(XMLSTARLET_BUILD) install
	ln -s $(BINDIR)/xml $(BINDIR)/xmlstarlet

uninstall-xmlstarlet:
	-$(MAKE) -C $(XMLSTARLET_BUILD) uninstall
	-$(RM) $(BINDIR)/xmlstarlet

$(SHAREDIR)/ocrd-tool.json: ocrd-tool.json
	@mkdir -p $(SHAREDIR)
	cp ocrd-tool.json $(SHAREDIR)

$(TOOLS:%=$(BINDIR)/%): $(BINDIR)/%: %
	@mkdir -p $(BINDIR)
	sed 's|^SHAREDIR=.*|SHAREDIR="$(SHAREDIR)"|;s|^PYTHON=.*|PYTHON="$(PYTHON)"|' $< > $@
	chmod a+x $@

install: install-olena $(SHAREDIR)/ocrd-tool.json $(TOOLS:%=$(BINDIR)/%)

uninstall: uninstall-olena
	-$(RM) $(SHAREDIR)/ocrd-tool.json
	-$(RM) $(TOOLS:%=$(BINDIR)/%)
	-$(RM) $(BINDIR)/scribo-cli

install-conda: install-xmlstarlet install

uninstall-conda: uninstall-xmlstarlet uninstall

.PHONY: install-olena uninstall-olena install-xmlstarlet uninstall-xmlstarlet \
		install uninstall install-conda uninstall-conda 

#
# Docker
#

docker: build-olena.dockerfile Dockerfile
	docker build -t $(DOCKER_TAG):build-olena -f build-olena.dockerfile .
	docker build -t $(DOCKER_TAG) .

.PHONY: docker

#
# Finishing
#

ifeq ($(findstring $(BINDIR),$(subst :, ,$(PATH))),)
	@echo "you need to add '$(BINDIR)' to your PATH"
else
	@echo "you already have '$(BINDIR)' in your PATH"
endif

# do not search for implicit rules here:
Makefile: ;
