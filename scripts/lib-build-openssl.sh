#!/bin/sh

#—————————————————————————————————————————————————————————————————————————————————————————
# Help
#—————————————————————————————————————————————————————————————————————————————————————————
echo_help()
{
  cat <<HEREDOC
Usage: $0 [options...]

Version options
     --branch=BRANCH               Select OpenSSL branch to build. The script will determine and 
                                   download the latest release for that branch. Note that this is
                                   not a git branch; it's a release branch, such as 1.1.1.
     --version=VERSION             OpenSSL version to build (defaults to ${DEFAULTVERSION})

SDK options
     --catalyst-sdk=SDKVERSION     Override macOS SDK version for catalyst
     --ios-sdk=SDKVERSION          Override iOS SDK version
     --macos-sdk=SDKVERSION        Override macOS SDK version
     --tvos-sdk=SDKVERSION         Override tvOS SDK version

Configuration options
     --disable-bitcode             Disable embedding Bitcode. Ignored for physical devices that
                                   require Bitcode in the App Store (Apple Watch and Apple TV)
     --ec-nistp-64-gcc-128         Enable config option enable-ec_nistp_64_gcc_128 for 64 bit builds
     --deprecated                  Exclude no-deprecated configure option and build with deprecated 
                                   methods

Building options
     --cleanup                     Clean up build directories (bin, include/openssl, lib, src) 
                                   before starting build
     --directory=DIRECTORY         Specify a root build directory for output. This directory must
                                   already exist. The default is the script directory.
     --noparallel                  Disable running make with parallel jobs (make -j)
 -v, --verbose                     Enable verbose logging
     --verbose-on-error            Dump last 500 lines from log if error occurs (for Travis builds)
     --targets="TARGET TARGET ..." Space-separated list of build targets, one or more of:
$(echo "${TARGETS_DEFAULT}" | fold -s -w 60  | sed -e "s|^|                                     |g")

Other options
 -h, --help                        Print help (this message)

For custom configure options, set variable CONFIG_OPTIONS
For custom cURL options, set variable CURL_OPTIONS
  Example: CURL_OPTIONS="--proxy 192.168.1.1:8080" $0

HEREDOC
}


#—————————————————————————————————————————————————————————————————————————————————————————
# Check for error status
#—————————————————————————————————————————————————————————————————————————————————————————
check_status()
{
  local STATUS=$1
  local COMMAND=$2

  if [ "${STATUS}" != 0 ]; then
    if [[ "${LOG_VERBOSE}" != "verbose"* ]]; then
      echo "Problem during ${COMMAND} - Please check ${LOG}"
    fi

    # Dump last 500 lines from log file for verbose-on-error
    if [ "${LOG_VERBOSE}" == "verbose-on-error" ]; then
      echo "Problem during ${COMMAND} - Dumping last 500 lines from log file"
      echo
      tail -n 500 "${LOG}"
    fi

    exit 1
  fi
}


#—————————————————————————————————————————————————————————————————————————————————————————
# Prepare target and source dir in build loop
#—————————————————————————————————————————————————————————————————————————————————————————
prepare_target_source_dirs()
{
  # Prepare target dir
  TARGETDIR="${CURRENTPATH}/bin/${SUBPLATFORM}${SDKVERSION}-${ARCH}.sdk"
  mkdir -p "${TARGETDIR}"
  LOG="${TARGETDIR}/build-openssl-${VERSION}.log"

  echo "Building openssl-${VERSION} for ${SUBPLATFORM} ${SDKVERSION} ${ARCH}..."
  echo "  Logfile: ${LOG}"

  # Prepare source dir
  SOURCEDIR="${CURRENTPATH}/src/${SUBPLATFORM}-${ARCH}"
  mkdir -p "${SOURCEDIR}"
  tar zxf "${CURRENTPATH}/${OPENSSL_ARCHIVE_FILE_NAME}" -C "${SOURCEDIR}"
  cd "${SOURCEDIR}/${OPENSSL_ARCHIVE_BASE_NAME}"
  chmod u+x ./Configure
}


#—————————————————————————————————————————————————————————————————————————————————————————
# Run Configure in build loop
#—————————————————————————————————————————————————————————————————————————————————————————
run_configure()
{
  echo "  Configure..."
  set +e
  if [ "${LOG_VERBOSE}" == "verbose" ]; then
    ./Configure ${LOCAL_CONFIG_OPTIONS} | tee "${LOG}"
  else
    (./Configure ${LOCAL_CONFIG_OPTIONS} > "${LOG}" 2>&1) & spinner
  fi

  # Check for error status
  check_status $? "Configure"
}


#—————————————————————————————————————————————————————————————————————————————————————————
# Run make in build loop
#—————————————————————————————————————————————————————————————————————————————————————————
run_make()
{
  echo "  Make (using ${BUILD_THREADS} thread(s))..."
  if [ "${LOG_VERBOSE}" == "verbose" ]; then
    make -j "${BUILD_THREADS}" | tee -a "${LOG}"
  else
    (make -j "${BUILD_THREADS}" >> "${LOG}" 2>&1) & spinner
  fi

  # Check for error status
  check_status $? "make"
}


#—————————————————————————————————————————————————————————————————————————————————————————
# Cleanup and bookkeeping at end of build loop
#—————————————————————————————————————————————————————————————————————————————————————————
finish_build_loop()
{
  # Return to ${CURRENTPATH} and remove source dir
  cd "${CURRENTPATH}"
  rm -r "${SOURCEDIR}"

  # Add references to library files to relevant arrays
  if [[ "${PLATFORM}" == AppleTV* ]]; then
    LIBSSL_TVOS+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_TVOS+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="tvos_${ARCH}"
  elif [[ "${PLATFORM}" == Watch* ]]; then
    LIBSSL_WATCHOS+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_WATCHOS+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="watchos_${ARCH}"
  elif [[ "${PLATFORM}" == iPhone* ]]; then
    LIBSSL_IOS+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_IOS+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="ios_${ARCH}"
  elif [[ "${SUBPLATFORM=}" == "Catalyst"* ]]; then
    LIBSSL_CATALYST+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_CATALYST+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="catalyst_${ARCH}"
  else
    LIBSSL_MACOS+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_MACOS+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="macos_${ARCH}"
  fi

  # Copy opensslconf.h to bin directory and add to array
  OPENSSLCONF="opensslconf_${OPENSSLCONF_SUFFIX}.h"
  cp "${TARGETDIR}/include/openssl/opensslconf.h" "${CURRENTPATH}/bin/${OPENSSLCONF}"
  OPENSSLCONF_ALL+=("${OPENSSLCONF}")

  # Keep reference to first build target for include file
  if [ -z "${INCLUDE_DIR}" ]; then
    INCLUDE_DIR="${TARGETDIR}/include/openssl"
  fi
}


#—————————————————————————————————————————————————————————————————————————————————————————
# The main build loop for each of our targets.
#—————————————————————————————————————————————————————————————————————————————————————————
target_build_loop()
{
    for TARGET in $TARGETS; do
      # Determine relevant SDK version
      if [[ "${TARGET}" == tvos* ]]; then
        SDKVERSION="${TVOS_SDKVERSION}"
      elif [[ "${TARGET}" == macos* ]]; then
        SDKVERSION="${MACOS_SDKVERSION}"
      elif [[ "${TARGET}" == mac-catalyst-* ]]; then
        SDKVERSION="${CATALYST_SDKVERSION}"
      elif [[ "${TARGET}" == watchos* ]]; then
        SDKVERSION="${WATCHOS_SDKVERSION}"
      else
        SDKVERSION="${IOS_SDKVERSION}"
      fi

      # These variables are used in the configuration file
      export CONFIG_DISABLE_BITCODE
      export SDKVERSION
      export IOS_MIN_SDK_VERSION
      export MACOS_MIN_SDK_VERSION
      export TVOS_MIN_SDK_VERSION
      export WATCHOS_MIN_SDK_VERSION

      # Determine platform
      if [[ "${TARGET}" == "ios-sim-cross-"* ]]; then
        PLATFORM="iPhoneSimulator"
      elif [[ "${TARGET}" == "tvos-sim-cross-"* ]]; then
        PLATFORM="AppleTVSimulator"
      elif [[ "${TARGET}" == "tvos64-cross-"* ]]; then
        PLATFORM="AppleTVOS"
      elif [[ "${TARGET}" == "macos"* ]]; then
        PLATFORM="MacOSX"
      elif [[ "${TARGET}" == "watchos-sim-cross"* ]]; then
        PLATFORM="WatchSimulator"
      elif [[ "${TARGET}" == "watchos"* ]]; then
        PLATFORM="WatchOS"
      elif [[ "${TARGET}" == "mac-catalyst-"* ]]; then
        PLATFORM="MacOSX"
      else
        PLATFORM="iPhoneOS"
      fi

      # Extract ARCH from TARGET (part after last dash)
      ARCH=$(echo "${TARGET}" | sed -E 's|^.*\-([^\-]+)$|\1|g')

      # Cross compile references, see Configurations/10-main.conf
      local SDK_NAME=`echo "${PLATFORM}" | tr '[:upper:]' '[:lower:]'`
      export CROSS_COMPILE="${DEVELOPER}/Toolchains/XcodeDefault.xctoolchain/usr/bin/"
      export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
      export CROSS_SDK="${PLATFORM}${SDKVERSION}.sdk"
      export CROSS_SYSROOT=`xcrun -sdk $SDK_NAME --show-sdk-path`

      # Prepare TARGETDIR and SOURCEDIR
      SUBPLATFORM="${PLATFORM}"
      if [[ "${TARGET}" == "mac-catalyst-"* ]]; then
        SUBPLATFORM="Catalyst"
      fi

      prepare_target_source_dirs

      ## Determine config options
      # Add build target, --prefix and prevent async (references to getcontext(),
      # setcontext() and makecontext() result in App Store rejections) and creation
      # of shared libraries (default since 1.1.0)
      LOCAL_CONFIG_OPTIONS="${TARGET} --prefix=${TARGETDIR} ${CONFIG_OPTIONS} no-async no-shared"

      # Only relevant for 64 bit builds
      if [[ "${CONFIG_ENABLE_EC_NISTP_64_GCC_128}" == "true" && "${ARCH}" == *64  ]]; then
        LOCAL_CONFIG_OPTIONS="${LOCAL_CONFIG_OPTIONS} enable-ec_nistp_64_gcc_128"
      fi
  
      # openssl-1.1.1 tries to use an unguarded fork(), affecting AppleTVOS and WatchOS.
      # Luckily this is only present in the testing suite and can be built without it.
      if [[ $PLATFORM == "AppleTV"* || $PLATFORM == "Watch"* ]]; then
        LOCAL_CONFIG_OPTIONS="${LOCAL_CONFIG_OPTIONS} no-tests"
      fi

      # Run Configure
      run_configure

      # Run make
      run_make

      # Run make install
      set -e

      if [ "${LOG_VERBOSE}" == "verbose" ]; then
        make install_dev | tee -a "${LOG}"
      else
        make install_dev >> "${LOG}" 2>&1
      fi

      # Remove source dir, add references to library files to relevant arrays
      # Keep reference to first build target for include file
      finish_build_loop
    done
}


#—————————————————————————————————————————————————————————————————————————————————————————
# Download open SSL if necessary.
#—————————————————————————————————————————————————————————————————————————————————————————
locate_openssl_archive()
{
	# Download OpenSSL when not present
	OPENSSL_ARCHIVE_BASE_NAME="openssl-${VERSION}"
	OPENSSL_ARCHIVE_FILE_NAME="${OPENSSL_ARCHIVE_BASE_NAME}.tar.gz"
	if [ ! -e "${CURRENTPATH}/${OPENSSL_ARCHIVE_FILE_NAME}" ]; then
	  echo "Downloading ${OPENSSL_ARCHIVE_FILE_NAME}..."
	  OPENSSL_ARCHIVE_URL="https://www.openssl.org/source/${OPENSSL_ARCHIVE_FILE_NAME}"

	  # Check whether file exists here (this is the location of the latest version for each branch)
	  # -s be silent, -f return non-zero exit status on failure, -I get header (do not download)
	  curl ${CURL_OPTIONS} -sfI "${OPENSSL_ARCHIVE_URL}" > /dev/null

	  # If unsuccessful, try the archive
	  if [ $? -ne 0 ]; then
		BRANCH=$(echo "${VERSION}" | grep -Eo '^[0-9]\.[0-9]\.[0-9]')
		OPENSSL_ARCHIVE_URL="https://www.openssl.org/source/old/${BRANCH}/${OPENSSL_ARCHIVE_FILE_NAME}"

		curl ${CURL_OPTIONS} -sfI "${OPENSSL_ARCHIVE_URL}" > /dev/null
	  fi

	  # Both attempts failed, so report the error
	  if [ $? -ne 0 ]; then
		echo "An error occurred trying to find OpenSSL ${VERSION} on ${OPENSSL_ARCHIVE_URL}"
		echo "Please verify that the version you are trying to build exists, check cURL's error message and/or your network connection."
		exit 1
	  fi

	  # Archive was found, so proceed with download.
	  # -O Use server-specified filename for download
	  (cd ${CURRENTPATH} && curl ${CURL_OPTIONS} -O "${OPENSSL_ARCHIVE_URL}")

	else
	  echo "Using ${OPENSSL_ARCHIVE_FILE_NAME}"
	fi
}