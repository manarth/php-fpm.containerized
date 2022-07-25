ARG PHP_SRC="https://github.com/php/php-src.git"
ARG PHP_RELEASE="php-8.0.20"

#################
# BUILD LIB-ZIP #
#################
FROM alpine:3.16 AS build-libzip

RUN apk add autoconf automake bison g++ gcc libc-dev libtool make re2c

RUN mkdir /opt/libzip

WORKDIR /opt/libzip

# @TODO: Consider referencing as a Git submodule.
RUN wget https://libzip.org/download/libzip-1.9.0.tar.xz
RUN tar -xJf libzip-1.9.0.tar.xz

WORKDIR /opt/libzip/libzip-1.9.0

RUN apk add cmake mbedtls-static samurai zlib-dev

RUN  cmake -B build -G Ninja \
-DBUILD_SHARED_LIBS=OFF \
-DCMAKE_INSTALL_PREFIX=/usr \
-DCMAKE_INSTALL_LIBDIR=lib \
-DENABLE_BZIP2=ON \
-DENABLE_LZMA=ON \
-DENABLE_OPENSSL=ON \
-DENABLE_ZSTD=ON \
-DCMAKE_BUILD_TYPE=MinSizeRel

RUN cmake --build build


#############
# BUILD PHP #
#############
FROM alpine:3.16 AS build-php
ARG PHP_SRC
ARG PHP_RELEASE

# Required to fetch the latest PHP source.
RUN apk add git

# Checkout the relevant PHP branch.
RUN git clone --depth 1 --branch ${PHP_RELEASE} ${PHP_SRC} /opt/php-src

# Required to compile PHP from source.
RUN apk add autoconf automake bison g++ gcc libc-dev libtool make re2c

# Copy the static-build of libzip.
COPY --from=build-libzip /opt/libzip/libzip-1.9.0/build/lib/libzip.a /lib/

# Extension-specific libraries.
RUN apk add bzip2-dev curl-dev icu-dev libgcrypt-dev libpng-dev libsodium-dev libxml2-dev libxslt-dev libzip-dev oniguruma-dev sqlite-dev tidyhtml-dev

# Static versions of the libraries for extensions.
RUN apk add bzip2-static curl-static icu-static libgcrypt-static libgpg-error-static libpng-static libsodium-static sqlite-static tidyhtml-static zlib-static

# Static lib dependencies of the static libs.
RUN apk add brotli-static nghttp2-static openssl-libs-static zstd-static

WORKDIR /opt/php-src

# Initialise the build environment.
RUN ./buildconf --force

# Configure the build.
RUN ./configure \
  # Set directories.
  --prefix= \
  --exec-prefix=/usr \
  --datarootdir=/usr/share \
  --with-config-file-path=/etc/php/ \
  --with-config-file-scan-dir=/etc/php/conf.d/ \
  --sysconfdir=/etc/php \
  # Use static-linking to create a self-contained binary.
  --enable-static \
  --disable-shared \
  # Select SAPI and basic configuration.
  --without-apxs2 \
  --enable-fpm \
  --disable-cgi \
  --disable-phpdbg \
  --enable-zts \
  # Global configuration.
  --disable-short-tags \
  # Standard extensions.
  --enable-bcmath \
  --with-bz2 \
  --with-curl \
  --enable-gd \
  --enable-intl \
  --enable-mbstring \
  --enable-pcntl \
  --enable-soap \
  --enable-sockets \
  --with-sodium \
  --with-tidy \
  --with-xsl \
  --with-zip \
  --with-libxml \
  --with-sqlite3 \
  --with-zlib

# Add the static-library dependencies as a variable to the Makefile.
RUN printf "\n# %s\n%s\n\n" \
    'Added by static-builder.' \
    'STATIC_EXTRA_LIBS="-lstdc++ -l:libnghttp2.a -l:libgcrypt.a -l:libgpg-error.a -l:libssl.a -l:libcrypto.a -l:libbrotlidec.a -l:libbrotlicommon.a -l:liblzma.a"' \
    | tee -a Makefile

# Add a new Makefile target to statically build the CLI SAPI.
RUN printf "%s\n%s\n\t%s\n\n" \
    'BUILD_STATIC_CLI = $(LIBTOOL) --mode=link $(CC) -export-dynamic -all-static $(CFLAGS_CLEAN) $(EXTRA_CFLAGS) $(EXTRA_LDFLAGS_PROGRAM) $(LDFLAGS) $(PHP_RPATHS) $(PHP_GLOBAL_OBJS:.lo=.o) $(PHP_BINARY_OBJS:.lo=.o) $(PHP_CLI_OBJS:.lo=.o) $(EXTRA_LIBS) $(ZEND_EXTRA_LIBS) $(STATIC_EXTRA_LIBS) -o $(SAPI_CLI_PATH)' \
    'cli-static: $(PHP_GLOBAL_OBJS) $(PHP_BINARY_OBJS) $(PHP_CLI_OBJS)' \
    '$(BUILD_STATIC_CLI)' \
    | tee -a Makefile

# Add a new Makefile target to statically build the FPM SAPI.
RUN printf "%s\n%s\n\t%s\n\n" \
    'BUILD_STATIC_FPM = $(LIBTOOL) --mode=link $(CC) -export-dynamic -all-static $(CFLAGS_CLEAN) $(EXTRA_CFLAGS) $(EXTRA_LDFLAGS_PROGRAM) $(LDFLAGS) $(PHP_RPATHS) $(PHP_GLOBAL_OBJS:.lo=.o) $(PHP_BINARY_OBJS:.lo=.o) $(PHP_FASTCGI_OBJS:.lo=.o) $(PHP_FPM_OBJS:.lo=.o) $(EXTRA_LIBS) $(FPM_EXTRA_LIBS) $(ZEND_EXTRA_LIBS) $(STATIC_EXTRA_LIBS) -o $(SAPI_FPM_PATH)' \
    'fpm-static: $(PHP_GLOBAL_OBJS) $(PHP_BINARY_OBJS) $(PHP_FASTCGI_OBJS) $(PHP_FPM_OBJS)' \
    '$(BUILD_STATIC_FPM)' \
    | tee -a Makefile

# Compile PHP.
RUN make cli-static fpm-static -j $(nproc)

# Strip symbols for a smaller binary.
RUN strip --strip-all /opt/php-src/sapi/fpm/php-fpm
RUN strip --strip-all /opt/php-src/sapi/cli/php

FROM alpine:3.16 AS dist

RUN mkdir -p /rootfs
RUN mkdir -p /rootfs/bin
RUN mkdir -p /rootfs/etc/php/conf.d/
RUN mkdir -p /rootfs/etc/php/php-fpm.d/
RUN mkdir -p /rootfs/usr/local/lib/php/extensions/no-debug-zts-20210902
RUN mkdir -p /rootfs/usr/sbin
RUN mkdir -p /rootfs/var/log

RUN cp /bin/false /rootfs/bin/false

# Create a placeholder /etc/passwd and /etc/group for `nobody`.
RUN echo "nobody:x:65534:65534:nobody:/:/bin/false" | tee /rootfs/etc/passwd
RUN echo "nobody:x:65534:" | tee /rootfs/etc/group

# Copy binary.
COPY --from=build-php /opt/php-src/sapi/fpm/php-fpm /rootfs/usr/sbin/php-fpm

# Copy config.
COPY --from=build-php /opt/php-src/php.ini-production     /rootfs/etc/php/php.ini
COPY --from=build-php /opt/php-src/sapi/fpm/php-fpm.conf  /rootfs/etc/php/php-fpm.conf
COPY --from=build-php /opt/php-src/sapi/fpm/www.conf      /rootfs/etc/php/php-fpm.d/www.conf.EXAMPLE


# Build the final no-OS layer.
FROM scratch
ARG PHP_RELEASE
STOPSIGNAL SIGTERM
COPY --from=dist /rootfs /
CMD ["/usr/sbin/php-fpm", "--nodaemonize"]
LABEL php.version=${PHP_RELEASE}
