#!/bin/sh

# Copyright (C) Viktor Szakats. See LICENSE.md
# SPDX-License-Identifier: MIT

# shellcheck disable=SC3040,SC2039
set -o xtrace -o errexit -o nounset; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

export _NAM _VER _OUT _BAS _DST

_NAM="$(basename "$0" | cut -f 1 -d '.')"; [ -n "${2:-}" ] && _NAM="$2"
_VER="$1"

(
  cd "${_NAM}" || exit 0

  # Required on MSYS2 for pod2man and pod2html in 'make install' phase
  [ "${_HOSTOS}" = 'win' ] && export PATH="${PATH}:/usr/bin/core_perl"

  readonly _ref='CHANGES.md'

  case "${_HOSTOS}" in
    bsd|mac) unixts="$(TZ=UTC stat -f '%m' "${_ref}")";;
    *)       unixts="$(TZ=UTC stat -c '%Y' "${_ref}")";;
  esac

  # Build

  rm -r -f "${_PKGDIR:?}" "${_BLDDIR:?}"

  options=''

  if [ "${_OS}" = 'win' ]; then
    [ "${_CPU}" = 'x86' ] && options="${options} mingw"
    [ "${_CPU}" = 'x64' ] && options="${options} mingw64"
    if [ "${_CPU}" = 'a64' ]; then
      # Source: https://github.com/openssl/openssl/issues/10533
      echo '## -*- mode: perl; -*-
        my %targets = (
          "mingw-arm64" => {
            inherit_from     => [ "mingw-common" ],
            asm_arch         => "aarch64",
            perlasm_scheme   => "win64",
            multilib         => "64",
          }
        );' > Configurations/11-curl-for-win-mingw-arm64.conf

      options="${options} mingw-arm64"
    fi
  elif [ "${_OS}" = 'mac' ]; then
    [ "${_CPU}" = 'x64' ] && options="${options} darwin64-x86_64"
    [ "${_CPU}" = 'a64' ] && options="${options} darwin64-arm64"
  elif [ "${_OS}" = 'linux' ]; then
    [ "${_CPU}" = 'x64' ] && options="${options} linux-x86_64"
    [ "${_CPU}" = 'a64' ] && options="${options} linux-aarch64"
  fi

  options="${options} ${_LDFLAGS_GLOBAL} ${_LIBS_GLOBAL} ${_CFLAGS_GLOBAL_CMAKE} ${_CFLAGS_GLOBAL} ${_CPPFLAGS_GLOBAL}"
  if [ "${_OS}" = 'win' ]; then
    options="${options} -DUSE_BCRYPTGENRANDOM -lbcrypt"
  fi
  [ "${_CPU}" = 'x86' ] || options="${options} enable-ec_nistp_64_gcc_128"

  if false && [ -n "${_ZLIB}" ]; then
    options="${options} --with-zlib-lib=${_TOP}/${_ZLIB}/${_PP}/lib"
    options="${options} --with-zlib-include=${_TOP}/${_ZLIB}/${_PP}/include"
    options="${options} zlib"
  else
    options="${options} no-comp"
  fi

  export CC="${_CC_GLOBAL}"

  # OpenSSL's ./Configure dumps build flags into object `crypto/cversion.o`
  # via `crypto/buildin.h` generated by `util/mkbuildinf.pl`. Thus, whitespace
  # changes, option order/duplicates do change binary output. Options like
  # `--sysroot=` are specific to the build environment, so this feature makes
  # it impossible to create reproducible binaries across build environments.
  # Patch OpenSSL to omit build options from its binary:
  sed -i.bak -E '/mkbuildinf/s/".+/""/' crypto/build.info

  # Patch OpenSSL ./Configure to:
  # - make it accept Windows-style absolute paths as --prefix. Without the
  #   patch it misidentifies all such absolute paths as relative ones and
  #   aborts.
  #   Reported: https://github.com/openssl/openssl/issues/9520
  # - allow no-apps option to save time building openssl command-line tool.
  sed \
    -e 's/die "Directory given with --prefix/print "Directory given with --prefix/g' \
    -e 's/"aria",$/"apps", "aria",/g' \
    < ./Configure > ./Configure-patched
  chmod a+x ./Configure-patched

  if [ "${_OS}" = 'win' ]; then
    # Space or backslash not allowed. Needs to be a folder restricted
    # to Administrators across Windows installations, versions and
    # configurations. We do avoid using the new default prefix set since
    # OpenSSL 1.1.1d, because by using the C:\Program Files*\ value, the
    # prefix remains vulnerable on localized Windows versions. The default
    # below gives a "more secure" configuration for most Windows installations.
    # Also notice that said OpenSSL default breaks OpenSSL's own build system
    # when used in cross-build scenarios. I submitted the working patch, but
    # closed subsequently due to mixed/no response. The secure solution would
    # be to disable loading anything from hard-coded paths and preferably to
    # detect OS location at runtime and adjust config paths accordingly; none
    # supported by OpenSSL.
    _my_prefix='C:/Windows/System32/OpenSSL'
  else
    _my_prefix='/etc'
  fi
  _ssldir="ssl"

  # 'no-dso' implies 'no-dynamic-engine' which in turn compiles in these
  # engines non-dynamically. To avoid them, also set `no-engine`.

  (
    mkdir "${_BLDDIR}"; cd "${_BLDDIR}"
    # shellcheck disable=SC2086
    ../Configure-patched ${options} \
      no-filenames \
      no-legacy \
      no-apps \
      no-autoload-config \
      no-engine \
      no-module \
      no-dso \
      no-shared \
      no-srp no-nextprotoneg \
      no-bf no-rc4 no-cast \
      no-idea no-cmac no-rc2 no-mdc2 no-whirlpool \
      no-dsa \
      no-tests \
      no-makedepend \
      "--prefix=${_my_prefix}" \
      "--openssldir=${_ssldir}"
  )

  SOURCE_DATE_EPOCH=${unixts} TZ=UTC make --directory="${_BLDDIR}" --jobs="${_JOBS}"
  # Ending slash required.
  make --directory="${_BLDDIR}" --jobs="${_JOBS}" install "DESTDIR=$(pwd)/${_PKGDIR}/" >/dev/null # 2>&1

  # OpenSSL 3.x does not strip the drive letter anymore:
  #   ./openssl/${_PKGDIR}/C:/Windows/System32/OpenSSL
  # Some tools (e.g. CMake) become weird when colons appear in a filename,
  # so move results to a sane, standard path:

  mkdir -p "./${_PP}"
  mv "${_PKGDIR}/${_my_prefix}"/* "${_PP}"

  # Rename 'lib64' to 'lib'. This is what most packages expect.
  if [ -d "${_PP}/lib64" ]; then
    mv "${_PP}/lib64" "${_PP}/lib"
  fi

  # Delete .pc files
  rm -r -f "${_PP}"/lib/pkgconfig

  # List files created
  find "${_PP}" | grep -a -v -F '/share/' | sort

  # Make steps for determinism

  "${_STRIP}" --enable-deterministic-archives --strip-debug "${_PP}"/lib/*.a

  touch -c -r "${_ref}" "${_PP}"/include/openssl/*.h
  touch -c -r "${_ref}" "${_PP}"/lib/*.a

  # Create package

  _OUT="${_NAM}-${_VER}${_REVSUFFIX}${_PKGSUFFIX}"
  _BAS="${_NAM}-${_VER}${_PKGSUFFIX}"
  _DST="$(pwd)/_pkg"; rm -r -f "${_DST}"

  mkdir -p "${_DST}/include/openssl"
  mkdir -p "${_DST}/lib"

  cp -f -p "${_PP}"/include/openssl/*.h "${_DST}/include/openssl/"
  cp -f -p "${_PP}"/lib/*.a             "${_DST}/lib"
  cp -f -p CHANGES.md                   "${_DST}/"
  cp -f -p LICENSE.txt                  "${_DST}/"
  cp -f -p README.md                    "${_DST}/"
  cp -f -p FAQ.md                       "${_DST}/"
  cp -f -p NEWS.md                      "${_DST}/"

  [ "${_NAM}" = 'quictls' ] && cp -f -p README-OpenSSL.md "${_DST}/"

  ../_pkg.sh "$(pwd)/${_ref}"
)
