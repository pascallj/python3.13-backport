# syntax=docker/dockerfile:1
ARG PYTHON_NAME="python3.13"
ARG PYTHON_VERSION="3.13.2-1"
ARG DIST_NAME="sid"

# -------------------- Preparation --------------------
FROM debian:bookworm-slim AS pre-build
ARG DIST_NAME
RUN echo "\
Types: deb deb-src\n\
URIs: http://deb.debian.org/debian\n\
Suites: ${DIST_NAME}\n\
Components: main\n\
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg" \
> /etc/apt/sources.list.d/${DIST_NAME}-src.sources
RUN echo "\
Package: *\n\
Pin: release n=${DIST_NAME}\n\
Pin-Priority: 1\n\
\n\
Package: libjs-sphinxdoc sphinx-common python3-sphinx python3-docs-theme python-babel-localedata docutils-common python3-alabaster python3-babel python3-docutils python3-pygments python3-requests\n\
Pin: release n=${DIST_NAME}\n\
Pin-Priority: 500" \
> /etc/apt/preferences.d/99pinning
RUN	apt-get update && \
	apt-get upgrade -y && \
	apt-get install -y --no-install-recommends devscripts equivs
	
# -------------------- Source preperation --------------------
FROM pre-build AS source
ARG PYTHON_NAME
ARG PYTHON_VERSION
WORKDIR /usr/local/src
RUN	apt-get source --download-only ${PYTHON_NAME}=${PYTHON_VERSION} && \
	dpkg-source -x --skip-patches ${PYTHON_NAME}*.dsc && \
	mv ${PYTHON_NAME}*/ python-source
WORKDIR python-source
ADD patches/*.diff debian/patches
ADD patches/series debian/patches/series_extra
RUN	sed -i '/^ensurepip-disabled.diff$/s/^/#/' debian/patches/series && \
	cat debian/patches/series_extra >> debian/patches/series
RUN dpkg-source --before-build .

ADD changelog_previous .
RUN if [ -s changelog_previous ]; then echo "$(cat changelog_previous)\n\
\n\
$(cat debian/changelog)" > debian/changelog; fi
ARG NAME
ARG EMAIL
ARG CHANGE
RUN dch --bpo "$CHANGE"

# -------------------- Build preperation --------------------
FROM pre-build AS build-system
# These packages would be installed by mk-build-deps for all architectures
# so make sure they are only downloaded once
# This command is allowed to fail however if something changes in the future
RUN 	apt-get install -y --no-install-recommends \
	diffstat docutils-common ed fontconfig-config fonts-dejavu-core libbrotli1 \
	libbsd0 libc-l10n libfontconfig1 libfreetype6 libjs-jquery libjson-perl \
	libjs-sphinxdoc libjs-underscore libpkgconf3 libpng16-16 libtcl8.6 \
	libtext-unidecode-perl libtk8.6 libx11-6 libx11-data libxau6 libxcb1 libxdmcp6 \
	libxext6 libxft2 libxml-libxml-perl libxml-namespacesupport-perl \
	libxml-sax-base-perl libxml-sax-perl libxrender1 libxss1 locales-all \
	lsb-release net-tools pkgconf-bin python3-alabaster python3-babel \
	python3-certifi python3-chardet python3-charset-normalizer python3-defusedxml \
	python3-docs-theme python3-docutils python3-idna python3-imagesize \
	python3-jinja2 python3-markupsafe python3-packaging python3-pkg-resources \
	python3-pygments python3-requests python3-roman python3-six \
	python3-snowballstemmer python3-sphinx python3-urllib3 python-babel-localedata \
	quilt sgml-base sharutils sphinx-common tcl tcl8.6 tex-common texinfo time tk \
	tk8.6 ucf x11-common x11proto-core-dev x11proto-dev xml-core xorg-sgml-doctools \
	xtrans-dev || \
	echo "::warning::Loading packages failed!" | tee -a /github_output
COPY --from=source /usr/local/src/python-source /usr/local/src/python-source
WORKDIR /usr/local/src/python-source

# -------------------- Build native architecture --------------------
FROM build-system AS native
RUN mk-build-deps --install --tool 'apt-get -y --no-install-recommends'

RUN debuild -b -uc -us
RUN mkdir debs && mv ../*.deb debs

# -------------------- Export native build artifacts --------------------
FROM scratch AS native-binaries
ARG PYTHON_NAME
COPY --from=native /usr/local/src/python-source/debs/. /usr/local/src/${PYTHON_NAME}*.build /usr/local/src/${PYTHON_NAME}*.buildinfo /

# -------------------- Crossbuild foreign architectures --------------------
FROM build-system AS crossbuild
ARG ARCH
RUN [ ! -z "${ARCH}" ]
RUN dpkg --add-architecture ${ARCH}
RUN apt-get update

ADD patches/crossbuild-dep.diff .
RUN patch -p1 < crossbuild-dep.diff

COPY --from=native /usr/local/src/python-source/debs native-debs
ARG PYTHON_NAME
RUN cd native-debs && apt-get install -y ./lib${PYTHON_NAME}-minimal*.deb \
	./lib${PYTHON_NAME}-stdlib*.deb \
	./lib${PYTHON_NAME}_*.deb \
	./${PYTHON_NAME}-minimal*.deb \
	./${PYTHON_NAME}_*.deb

RUN DEB_BUILD_PROFILES='nocheck nobench' DEB_BUILD_OPTIONS='nocheck nobench' mk-build-deps --arch ${ARCH} --host-arch ${ARCH}
# We don't need build-essential for cross-compiling, but mk-build-deps insists of adding it
# Hacky way to remove that:
RUN	mkdir rebuild-cross-deps && \
	dpkg-deb -R ${PYTHON_NAME}-cross-build-deps*.deb rebuild-cross-deps && \
	sed -i 's/build-essential:[^ ]* //' rebuild-cross-deps/DEBIAN/control && \
	dpkg-deb -b rebuild-cross-deps
RUN apt-get install -y --no-install-recommends ./rebuild-cross-deps.deb

RUN DEB_BUILD_PROFILES='nocheck nobench' DEB_BUILD_OPTIONS='nocheck nobench' debuild -b -uc -us -a${ARCH} --ignore-builtin-builddeps
RUN mkdir debs && mv ../*.deb debs

# -------------------- Export crossbuild artifacts --------------------
FROM scratch AS crossbuild-binaries
ARG PYTHON_NAME
COPY --from=crossbuild /usr/local/src/python-source/debs/. /usr/local/src/${PYTHON_NAME}*.build /usr/local/src/${PYTHON_NAME}*.buildinfo /
