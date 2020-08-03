#!/bin/sh

#
#  Automatic build script for libssl and libcrypto for macOS and Apple devices.
#
#  There are a lot of build scripts for OpenSSL on Apple platforms out there, but
#  this one differs such:
#
#  - builds XCFrameworks (hence the repository name) with truly universal libraries. With Xcode 11
#    and newer, XCFrameworks offer a single package with frameworks for every, single Apple
#    architecture. You no longer have to use run script build phases to slice and dice binary files;
#    Xcode will choose the right framework for the given target.
#
#  - Supports all of the xcode $STANDARD_ARCHS by default for each Apple platform. This means that
#    the frameworks work with your Xcode project right out of the box, with no fussing about with
#    VALID_ARCHITECTURES, etc. It's tempting to leave old architectures (armv7, for example) behind,
#    but Apple still seems to expect them.
#
#  - Builds traditional dynamic or static platform-specific frameworks, should that be your cup of
#    tea.
#
#  - Builds traditional dylibs or static libraries (libcrypto.{dylib,a}, libssl.{dylib,a}), should
#    that be your preferred poison.
#
#  - Supports installation via Carthage via the use of a fake framework.
#
#  - Supports OpenSSL-1.1.1d and newer. It might work with version 1.1.0, but testing begins with
#    1.1.1d. Versions prior to 1.1.0 are definitely *not* supported. This is a forward-thinking
#    distribution; it's time to bite the bullet and update to the new API's.
#
#  Changes by Jim Derry during November-December 2019.
#  Copyright 2019 Jim Derry. All right reserved.
#
#  Created by Felix Schulze on 16.12.10.
#  Copyright 2010-2017 Felix Schulze. All rights reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
#

#—————————————————————————————————————————————————————————————————————————————————————————
# INITIALIZATION
#—————————————————————————————————————————————————————————————————————————————————————————

# -u Attempt to use undefined variable outputs error message, and forces an exit
set -u

# Determine script directory
SCRIPTDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)


#—————————————————————————————————————————————————————————————————————————————————————————
# SCRIPT DEFAULTS
#—————————————————————————————————————————————————————————————————————————————————————————

# Default version in case no version is specified.
DEFAULTVERSION="1.1.1d"

# Available set of targets to build. This is distinct from the default set, below, in that this
# reflects everything that's available to build, whereas you may want to choose a different set
# of defaults.
TARGETS_AVAILABLE="ios-sim-cross-x86_64 ios-cross-armv7 ios64-cross-arm64 mac-catalyst-x86_64 tvos-sim-cross-x86_64 tvos64-cross-arm64 macos64-x86_64 macos64-arm64 watchos-cross-armv7k watchos-cross-arm64_32 watchos-sim-cross-i386"

# Default set of architectures (OpenSSL <= 1.0.2) or targets (OpenSSL >= 1.1.1) to build
TARGETS_DEFAULT="$TARGETS_AVAILABLE"

# Init optional env variables (use available variable or default to empty string)
CURL_OPTIONS="${CURL_OPTIONS:-}"
CONFIG_OPTIONS="${CONFIG_OPTIONS:-}"


#—————————————————————————————————————————————————————————————————————————————————————————
# IMPORT EXTERNAL RESOURCES
#—————————————————————————————————————————————————————————————————————————————————————————

source "${SCRIPTDIR}/scripts/lib-min-sdk-versions.sh"
source "${SCRIPTDIR}/scripts/lib-spinner.sh"
source "${SCRIPTDIR}/scripts/lib-build-openssl.sh"


#—————————————————————————————————————————————————————————————————————————————————————————
# PROCESS COMMAND LINE ARGUMENTS
#—————————————————————————————————————————————————————————————————————————————————————————

# Init optional command line vars
BRANCH=""
BUILD_DIR=""
CLEANUP=""
CONFIG_ENABLE_EC_NISTP_64_GCC_128=""
CONFIG_DISABLE_BITCODE=""
CONFIG_NO_DEPRECATED=""
MACOS_SDKVERSION=""
CATALYST_SDKVERSION=""
IOS_SDKVERSION=""
WATCHOS_SDKVERSION=""
LOG_VERBOSE=""
PARALLEL=""
TARGETS=""
TVOS_SDKVERSION=""
VERSION=""

# Process command line arguments
for i in "$@"; do
	case $i in
	  --branch=*)
		BRANCH="${i#*=}"
		shift
		;;
	  --catalyst-sdk=*)
		CATALYST_SDKVERSION="${i#*=}"
		shift
		;;
	  --cleanup)
		CLEANUP="true"
		;;
	  --directory=*)
		BUILD_DIR="${i#*=}"
		BUILD_DIR="${BUILD_DIR/#\~/$HOME}"
		shift
		;;
	  --deprecated)
		CONFIG_NO_DEPRECATED="false"
		;;
	  --ec-nistp-64-gcc-128)
		CONFIG_ENABLE_EC_NISTP_64_GCC_128="true"
		;;
	  --disable-bitcode)
	   CONFIG_DISABLE_BITCODE="true"
	   ;;
	  -h|--help)
		echo_help
		exit
		;;
	  --ios-sdk=*)
		IOS_SDKVERSION="${i#*=}"
		shift
		;;
	  --macos-sdk=*)
		MACOS_SDKVERSION="${i#*=}"
		shift
		;;
	  --noparallel)
		PARALLEL="false"
		;;
	  --targets=*)
		TARGETS="${i#*=}"
		shift
		;;
	  --tvos-sdk=*)
		TVOS_SDKVERSION="${i#*=}"
		shift
		;;
	  --watchos-sdk=*)
		WATCHOS_SDKVERSION="${i#*=}"
		shift
		;;
	  -v|--verbose)
		LOG_VERBOSE="verbose"
		;;
	  --verbose-on-error)
		LOG_VERBOSE="verbose-on-error"
		;;
	  --version=*)
		VERSION="${i#*=}"
		shift
		;;
	  *)
		echo "Unknown argument: ${i}"
		exit 1
		;;
	esac
done


#—————————————————————————————————————————————————————————————————————————————————————————
# VALIDATE OPTIONS AND COMMAND LINE ARGUMENTS
#—————————————————————————————————————————————————————————————————————————————————————————

# Don't mix version and branch
if [[ -n "${VERSION}" && -n "${BRANCH}" ]]; then
  echo "Either select a branch (the script will determine and build the latest version),"
  echo "or select a specific version, but not both."
  exit 1

# Specific version: Verify version number format. Expected: dot notation
elif [[ -n "${VERSION}" && ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]*$ ]]; then
  echo "Unknown version number format. Examples: 1.1.0, 1.1.1d"
  exit 1

# Specific branch
elif [ -n "${BRANCH}" ]; then
  # Verify version number format. Expected: dot notation
  if [[ ! "${BRANCH}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unknown branch version number format. Examples: 1.1.0, 1.1.1"
    exit 1

  # Valid version number, determine latest version
  else
    echo "Checking latest version of ${BRANCH} branch on openssl.org..."
    # Get directory content listing of /source/ (only contains latest version per branch).
    # Limit list to archives (so one archive per branch).
    # Filter for the requested branch, sort the list and get the last item (the last two steps
    # ensure there is always 1 result)
    VERSION=$(curl ${CURL_OPTIONS} -s https://ftp.openssl.org/source/ | grep -Eo '>openssl-[0-9]\.[0-9]\.[0-9][a-z]*\.tar\.gz<' | grep -Eo "${BRANCH//./\.}[a-z]*" | sort | tail -1)

    # Verify result
    if [ -z "${VERSION}" ]; then
      echo "Could not determine latest version; please check https://www.openssl.org/source/ for"
      echo "extant versions, and run this script again with then --version option."
      exit 1
    fi
  fi

# Script default
elif [ -z "${VERSION}" ]; then
  VERSION="${DEFAULTVERSION}"
fi

# OpenSSL branches <= 1.1.0: Significant changes to the build process were introduced with 
# OpenSSL 1.1.0, and as such, versions prior to this are unsupported by this script.
if [[ "${VERSION}" =~ ^(0\.9|1\.0) ]]; then
  echo "OpenSSL versions lower than 1.1.0 are not supported by this build script."
  exit 1
fi


#—————————————————————————————————————————————————————————————————————————————————————————
# SETUP AND VERIFY BUILD ENVIRONMENT
#—————————————————————————————————————————————————————————————————————————————————————————

# Set default for TARGETS if not specified
if [ ! -n "${TARGETS}" ]; then
  TARGETS="${TARGETS_DEFAULT}"
fi

# Add no-deprecated config option (if not overwritten)
# Using xargs neatly trims any leading whitespace. This is purely cosmetic.
if [ "${CONFIG_NO_DEPRECATED}" != "false" ]; then
  CONFIG_OPTIONS=$(echo "${CONFIG_OPTIONS} no-deprecated" | xargs)
fi

# Determine SDK versions
if [ ! -n "${MACOS_SDKVERSION}" ]; then
  MACOS_SDKVERSION=$(xcrun -sdk macosx --show-sdk-version)
fi
if [ ! -n "${CATALYST_SDKVERSION}" ]; then
  CATALYST_SDKVERSION=$(xcrun -sdk macosx --show-sdk-version)
fi
if [ ! -n "${IOS_SDKVERSION}" ]; then
  IOS_SDKVERSION=$(xcrun -sdk iphoneos --show-sdk-version)
fi
if [ ! -n "${TVOS_SDKVERSION}" ]; then
  TVOS_SDKVERSION=$(xcrun -sdk appletvos --show-sdk-version)
fi
if [ ! -n "${WATCHOS_SDKVERSION}" ]; then
  WATCHOS_SDKVERSION=$(xcrun -sdk watchos --show-sdk-version)
fi

# Determine number of cores for (parallel) build
BUILD_THREADS=1
if [ "${PARALLEL}" != "false" ]; then
  BUILD_THREADS=$(sysctl hw.ncpu | awk '{print $2}')
fi

# Write files relative to current location and validate directory
CURRENTPATH=${BUILD_DIR:-$(pwd)}
case "${CURRENTPATH}" in
  *\ * )
    echo "Your path contains whitespace, which is not supported by 'make install'."
    exit 1
  ;;
esac

if [[ ! -d ${CURRENTPATH} ]]; then
    echo "The root build directory must already exist."
    exit 1
fi

# From here, all the action takes place here.
cd "${CURRENTPATH}"

# Validate Xcode Developer path
DEVELOPER=$(xcode-select -print-path)
if [ ! -d "${DEVELOPER}" ]; then
  echo "Xcode path is not set correctly; ${DEVELOPER} does not exist"
  echo "run"
  echo "sudo xcode-select -switch <Xcode path>"
  echo "for default installation:"
  echo "sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

case "${DEVELOPER}" in
  *\ * )
    echo "Your Xcode path contains whitespaces, which is not supported."
    exit 1
  ;;
esac


#—————————————————————————————————————————————————————————————————————————————————————————
# FINAL PREREQUISITES
#—————————————————————————————————————————————————————————————————————————————————————————

cat <<HEREDOC

OpenSSL Build Details:
       OpenSSL version: ${VERSION}
               Targets: $(echo ${TARGETS} | fold -s -w 56  | sed -e "2,\$s|^|                        |g")
             macOS SDK: ${MACOS_SDKVERSION}
  macOS SDK (Catalyst): ${CATALYST_SDKVERSION}
               iOS SDK: ${IOS_SDKVERSION}
              tvOS SDK: ${TVOS_SDKVERSION}
           watchOS SDK: ${WATCHOS_SDKVERSION}
     Bitcode embedding: $([[ ${CONFIG_DISABLE_BITCODE} == true ]] && echo disabled || echo enabled )
Number of make threads: ${BUILD_THREADS}
        Build location: ${CURRENTPATH}
     Configure options: ${CONFIG_OPTIONS}

HEREDOC

# Download OpenSSL when not present
locate_openssl_archive

# Set reference to custom configuration. This lets the openssl build system know that
# we have our own configurations.
export OPENSSL_LOCAL_CONFIG_DIR="${SCRIPTDIR}/config"

# -e           Abort script at first error, when a command exits with non-zero status (except in until or
#              while loops, if-tests, list constructs)
# -o pipefail  Causes a pipeline to return the exit status of the last command in the pipe that
#              returned a non-zero return value
set -eo pipefail

# Clean up target directories if requested and present
if [ "${CLEANUP}" == "true" ]; then
  if [ -d "${CURRENTPATH}/bin" ]; then
    rm -r "${CURRENTPATH}/bin"
  fi
  if [ -d "${CURRENTPATH}/include/openssl" ]; then
    rm -r "${CURRENTPATH}/include/openssl"
  fi
  if [ -d "${CURRENTPATH}/lib" ]; then
    rm -r "${CURRENTPATH}/lib"
  fi
  if [ -d "${CURRENTPATH}/src" ]; then
    rm -r "${CURRENTPATH}/src"
  fi
fi

# (Re-)create target directories
mkdir -p "${CURRENTPATH}/bin"
mkdir -p "${CURRENTPATH}/lib"
mkdir -p "${CURRENTPATH}/src"
mkdir -p "${CURRENTPATH}/include"


#—————————————————————————————————————————————————————————————————————————————————————————
# BUILD
#—————————————————————————————————————————————————————————————————————————————————————————

# Init vars for library references
INCLUDE_DIR=""
OPENSSLCONF_ALL=()
LIBSSL_MACOS=()
LIBCRYPTO_MACOS=()
LIBSSL_CATALYST=()
LIBCRYPTO_CATALYST=()
LIBSSL_IOS=()
LIBCRYPTO_IOS=()
LIBSSL_TVOS=()
LIBCRYPTO_TVOS=()
LIBSSL_WATCHOS=()
LIBCRYPTO_WATCHOS=()


# Run build loop
target_build_loop


#Build macOS library if selected for build
if [ ${#LIBSSL_MACOS[@]} -gt 0 ]; then
  echo "Build library for macOS..."
  lipo -create ${LIBSSL_MACOS[@]} -output "${CURRENTPATH}/lib/libssl-MacOSX.a"
  lipo -create ${LIBCRYPTO_MACOS[@]} -output "${CURRENTPATH}/lib/libcrypto-MacOSX.a"
fi

#Build catalyst library if selected for build
if [ ${#LIBSSL_CATALYST[@]} -gt 0 ]; then
  echo "Build library for catalyst..."
  lipo -create ${LIBSSL_CATALYST[@]} -output "${CURRENTPATH}/lib/libssl-Catalyst.a"
  lipo -create ${LIBCRYPTO_CATALYST[@]} -output "${CURRENTPATH}/lib/libcrypto-Catalyst.a"
fi

# Build iOS library if selected for build
if [ ${#LIBSSL_IOS[@]} -gt 0 ]; then
  echo "Build library for iOS..."
  lipo -create ${LIBSSL_IOS[@]} -output "${CURRENTPATH}/lib/libssl-iPhone.a"
  lipo -create ${LIBCRYPTO_IOS[@]} -output "${CURRENTPATH}/lib/libcrypto-iPhone.a"
fi

# Build tvOS library if selected for build
if [ ${#LIBSSL_TVOS[@]} -gt 0 ]; then
  echo "Build library for tvOS..."
  lipo -create ${LIBSSL_TVOS[@]} -output "${CURRENTPATH}/lib/libssl-AppleTV.a"
  lipo -create ${LIBCRYPTO_TVOS[@]} -output "${CURRENTPATH}/lib/libcrypto-AppleTV.a"
fi

# Build tvOS library if selected for build
if [ ${#LIBSSL_WATCHOS[@]} -gt 0 ]; then
  echo "Build library for watchOS..."
  lipo -create ${LIBSSL_WATCHOS[@]} -output "${CURRENTPATH}/lib/libssl-WatchOS.a"
  lipo -create ${LIBCRYPTO_WATCHOS[@]} -output "${CURRENTPATH}/lib/libcrypto-WatchOS.a"
fi

# Copy include directory
cp -R "${INCLUDE_DIR}" "${CURRENTPATH}/include/"

# Only create intermediate file when building for multiple targets
# For a single target, opensslconf.h is still present in $INCLUDE_DIR (and has just been copied 
# to the target include dir)
if [ ${#OPENSSLCONF_ALL[@]} -gt 1 ]; then

  # Prepare intermediate header file
  # This overwrites opensslconf.h that was copied from $INCLUDE_DIR
  OPENSSLCONF_INTERMEDIATE="${CURRENTPATH}/include/openssl/opensslconf.h"
  cp "${SCRIPTDIR}/include/opensslconf-template.h" "${OPENSSLCONF_INTERMEDIATE}"

  # Loop all header files
  LOOPCOUNT=0
  for OPENSSLCONF_CURRENT in "${OPENSSLCONF_ALL[@]}" ; do

    # Copy specific opensslconf file to include dir
    cp "${CURRENTPATH}/bin/${OPENSSLCONF_CURRENT}" "${CURRENTPATH}/include/openssl"

    # Determine define condition
    case "${OPENSSLCONF_CURRENT}" in
      *_macos_x86_64.h)
        DEFINE_CONDITION="TARGET_OS_OSX && TARGET_CPU_X86_64"
      ;;
      *_macos_arm64.h)
        DEFINE_CONDITION="TARGET_OS_OSX && TARGET_CPU_ARM64"
      ;;
      *_macos_i386.h)
        DEFINE_CONDITION="TARGET_OS_OSX && TARGET_CPU_X86"
      ;;
      *_ios_x86_64.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_SIMULATOR && TARGET_CPU_X86_64"
      ;;
      *_ios_i386.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_SIMULATOR && TARGET_CPU_X86"
      ;;
      *_ios_arm64.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_EMBEDDED && TARGET_CPU_ARM64"
      ;;
      *_ios_armv7s.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_EMBEDDED && TARGET_CPU_ARM && defined(__ARM_ARCH_7S__)"
      ;;
      *_ios_armv7.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_EMBEDDED && TARGET_CPU_ARM && !defined(__ARM_ARCH_7S__)"
      ;;
      *_tvos_x86_64.h)
        DEFINE_CONDITION="TARGET_OS_TV && TARGET_OS_SIMULATOR && TARGET_CPU_X86_64"
      ;;
      *_tvos_arm64.h)
        DEFINE_CONDITION="TARGET_OS_TV && TARGET_OS_EMBEDDED && TARGET_CPU_ARM64"
      ;;
      *_watchos_armv7k.h)
        DEFINE_CONDITION="TARGET_OS_WATCHOS && TARGET_OS_EMBEDDED && TARGET_CPU_ARMV7K"
      ;;
      *_watchos_arm64_32.h)
        DEFINE_CONDITION="TARGET_OS_WATCHOS && TARGET_OS_EMBEDDED && TARGET_CPU_ARM64_32"
      ;;
      *_watchos_i386.h)
        DEFINE_CONDITION="TARGET_OS_SIMULATOR && TARGET_CPU_X86 || TARGET_OS_EMBEDDED"
      ;;
      *_catalyst_x86_64.h)
        DEFINE_CONDITION="(TARGET_OS_MACCATALYST || (TARGET_OS_IOS && TARGET_OS_SIMULATOR)) && TARGET_CPU_X86_64"      ;;
      *)
        # Don't run into unexpected cases by setting the default condition to false
        DEFINE_CONDITION="0"
      ;;
    esac

    # Determine loopcount; start with if and continue with elif
    LOOPCOUNT=$((LOOPCOUNT + 1))
    if [ ${LOOPCOUNT} -eq 1 ]; then
      echo "#if ${DEFINE_CONDITION}" >> "${OPENSSLCONF_INTERMEDIATE}"
    else
      echo "#elif ${DEFINE_CONDITION}" >> "${OPENSSLCONF_INTERMEDIATE}"
    fi

    # Add include
    echo "# include <openssl/${OPENSSLCONF_CURRENT}>" >> "${OPENSSLCONF_INTERMEDIATE}"
  done

  # Finish
  echo "#else" >> "${OPENSSLCONF_INTERMEDIATE}"
  echo '# error Unable to determine target or target not included in OpenSSL build' >> "${OPENSSLCONF_INTERMEDIATE}"
  echo "#endif" >> "${OPENSSLCONF_INTERMEDIATE}"
fi

echo "Done."
