#!/bin/bash

#—————————————————————————————————————————————————————————————————————————————————————————
# Output help information.
#—————————————————————————————————————————————————————————————————————————————————————————
echo_help() {
  cat <<HEREDOC
Usage: $0 [options...] static|xcstatic|dynamic|xcdynamic
Options
     --directory=DIRECTORY         Specify the root build directory where libssl was built. The
                                   default is the script directory.
     --frameworks=DIRECTORY        Specify the directory name to output the finished frameworks,
                                   relative to the root build directory. Default is "frameworks".
Commands
     static                        Build per-platform frameworks meant for static linking.
     xcstatic                      Build an XCFramework meant for static linking.
     dynamic                       Build per-platform frameworks meant for dynamic linking.
     xcdynamic                     Build an XCFramework meant for dynamic linking.
     carthage                      Build the Xcode project via Carthage and Archive it. Really only
                                   useful for the maintainer to prepare the binary version of this
                                   package.
     
The command specified above will build the specified library type based on the targets that were
built with the "build-libssl.sh" script, which must be used first in order to build the object
files.

HEREDOC
}


#—————————————————————————————————————————————————————————————————————————————————————————
# check whether or not bitcode is present in a framework.
#   $1: Path to framework to check.
#—————————————————————————————————————————————————————————————————————————————————————————
function check_bitcode() {
    local FWDIR=$1

    if [[ $FWTYPE == "dynamic" ]]; then
   		BITCODE_PATTERN="__LLVM"
    else
    	BITCODE_PATTERN="__bitcode"
	fi

	if otool -l "$FWDIR/$FWNAME" | grep "${BITCODE_PATTERN}" >/dev/null; then
       		echo "INFO: $FWDIR contains Bitcode"
	else
        	echo "INFO: $FWDIR doesn't contain Bitcode"
	fi
}


#—————————————————————————————————————————————————————————————————————————————————————————
# make macos symlinks
#   $1: Path of the framework to check/fix.
#   $2: The system type from ALL_SYSTEMS of the framework.
#—————————————————————————————————————————————————————————————————————————————————————————
function make_mac_symlinks() {
    local SYSTYPE=$2
    if [[ $SYSTYPE == "MacOSX" ]]; then
		local FWDIR=$1
		local CURRENT=$(pwd)
		cd $FWDIR

		mkdir "Versions"
		mkdir "Versions/A"
		mkdir "Versions/A/Resources"
		mv "openssl" "Headers" "Versions/A"
		mv "Info.plist" "Versions/A/Resources"

		(cd "Versions" && ln -s "A" "Current")
		ln -s "Versions/Current/openssl"
		ln -s "Versions/Current/Headers"
		ln -s "Versions/Current/Resources"
	
		cd $CURRENT
	fi
}


#—————————————————————————————————————————————————————————————————————————————————————————
# Build a dynamic library for each architecture found in bin, as well as combine the
# individual libraries into a single static library suitable for use in a framework.
#—————————————————————————————————————————————————————————————————————————————————————————
function build_libraries() {
    DEVELOPER=`xcode-select -print-path`
    FW_EXEC_NAME="${FWNAME}.framework/${FWNAME}"
    INSTALL_NAME="@rpath/${FW_EXEC_NAME}"
    COMPAT_VERSION="1.0.0"
    CURRENT_VERSION="1.0.0"

    RX='([A-z]+)([0-9]+(\.[0-9]+)*)-([A-z0-9]+)\.sdk'

    cd $BUILD_DIR/bin
    
    #
    # build the individual dylibs
    #
    for TARGETDIR in `ls -d *.sdk`; do
        if [[ $TARGETDIR =~ $RX ]]; then
            PLATFORM="${BASH_REMATCH[1]}"
            SDKVERSION="${BASH_REMATCH[2]}"
            ARCH="${BASH_REMATCH[4]}"
        fi
        
        _platform="${PLATFORM}"
        if [[ "${PLATFORM}" == "Catalyst" ]]; then
          _platform="MacOSX"
        fi

        echo "Assembling .dylib and .a for $PLATFORM $SDKVERSION ($ARCH)"

        CROSS_TOP="${DEVELOPER}/Platforms/${_platform}.platform/Developer"
        CROSS_SDK="${_platform}${SDKVERSION}.sdk"
        SDK="${CROSS_TOP}/SDKs/${CROSS_SDK}"

        if [[ $PLATFORM == AppleTVSimulator* ]]; then
            MIN_SDK="-tvos_simulator_version_min $TVOS_MIN_SDK_VERSION"
        elif [[ $PLATFORM == AppleTV* ]]; then
            MIN_SDK="-tvos_version_min $TVOS_MIN_SDK_VERSION"
        elif [[ $PLATFORM == MacOSX* ]]; then
            MIN_SDK="-macosx_version_min $MACOS_MIN_SDK_VERSION"
            if [[ $ARCH == arm64 ]]; then
                MIN_SDK="-macosx_version_min 11.0"
            fi
        elif [[ $PLATFORM == Catalyst* ]]; then
            MIN_SDK="-platform_version mac-catalyst 13.0 $CATALYST_MIN_SDK_VERSION"
        elif [[ $PLATFORM == iPhoneSimulator* ]]; then
            MIN_SDK="-ios_simulator_version_min $IOS_MIN_SDK_VERSION"
        elif [[ $PLATFORM == WatchOS* ]]; then
            MIN_SDK="-watchos_version_min 4.0"
        elif [[ $PLATFORM == WatchSimulator* ]]; then
            MIN_SDK="-watchos_simulator_version_min $WATCHOS_MIN_SDK_VERSION"
        else
            MIN_SDK="-ios_version_min $IOS_MIN_SDK_VERSION"
        fi

        local ISBITCODE=""
        if otool -l "$TARGETDIR/lib/libcrypto.a" | grep "__bitcode" >/dev/null; then
            ISBITCODE="-bitcode_bundle"
        fi
        
        TARGETOBJ="${TARGETDIR}/obj"
        rm -rf $TARGETOBJ
        mkdir $TARGETOBJ
        cd $TARGETOBJ
        ar -x ../lib/libcrypto.a
        ar -x ../lib/libssl.a
        cd ..

        libtool -static -no_warning_for_no_symbols -o ${FWNAME}.a lib/libcrypto.a lib/libssl.a

        ld obj/*.o \
            -dylib \
            $ISBITCODE \
            -lSystem \
            -arch $ARCH \
            $MIN_SDK \
            -syslibroot $SDK \
            -compatibility_version $COMPAT_VERSION \
            -current_version $CURRENT_VERSION \
            -application_extension \
            -o $FWNAME.dylib
        install_name_tool -id $INSTALL_NAME $FWNAME.dylib

        rm -rf obj/
        cd ..
    done
    cd ..
}


#—————————————————————————————————————————————————————————————————————————————————————————
# build a dynamic framework given the list of targets.
#  $1: a list of targets or directory names for which to build a framework.
#  $2: The system type, needed when passing directory names.
#—————————————————————————————————————————————————————————————————————————————————————————
build_dynamic_framework() {
    local FWDIR="$1"
    local SYS="$2"
    local FILES=($3)

    echo -e "\nTargets:"
    for target in ${FILES[@]}; do
        if otool -l "$target" | grep "__LLVM" >/dev/null; then
            echo "   $target (contains bitcode)"
        else
            echo "   $target (without bitcode)"
        fi
    done


    if [[ ${#FILES[@]} -gt 0 && -e ${FILES[0]} ]]; then
        printf "Creating dynamic framework for $SYS ($(basename $(dirname $FWDIR)))..."
        mkdir -p $FWDIR/Headers
        lipo -create ${FILES[@]} -output $FWDIR/$FWNAME
        cp -r include/$FWNAME/* $FWDIR/Headers/
        cp -L $SCRIPTDIR/assets/$SYS/Info.plist $FWDIR/Info.plist
        echo -e " done:\n   $FWDIR"
        check_bitcode $FWDIR
        make_mac_symlinks $FWDIR $SYS
    else
        echo "Skipped framework for $SYS"
    fi
}


#—————————————————————————————————————————————————————————————————————————————————————————
# build static frameworks given the list of targets.
#  $1: Output directory for the framework.
#  $2: System type of the framework.
#  $3: List of library files to embed in the framework.
#—————————————————————————————————————————————————————————————————————————————————————————
build_static_framework() {
    local FWDIR="$1"
    local SYS="$2"
    local FILES=($3)

    echo -e "\nCreating static framework for $SYS"
    for FILE in ${FILES[@]}; do
        if otool -l "$FILE" | grep "__bitcode" >/dev/null; then
            echo "   $FILE (contains bitcode)"
        else
            echo "   $FILE (without bitcode)"
        fi
    done
    mkdir -p $FWDIR/Headers
    
    # Don't lipo single files.
    if [[ ${#FILES[@]} -gt 1 ]]; then
        lipo -create ${FILES[@]} -output $FWDIR/$FWNAME
    else
        cp ${FILES[0]} $FWDIR/$FWNAME
    fi
    
    cp -r include/$FWNAME/* $FWDIR/Headers/
    cp -L $SCRIPTDIR/assets/$SYS/Info.plist $FWDIR/Info.plist
    echo "Created $FWDIR"
    check_bitcode $FWDIR
    make_mac_symlinks $FWDIR $SYS
}


#—————————————————————————————————————————————————————————————————————————————————————————
# build an XCFramework in the frameworks directory, with the assumption that the 
# individual, desired architecture frameworks are already present.
#—————————————————————————————————————————————————————————————————————————————————————————
build_xcframework() {
    local FRAMEWORKS=($BUILD_DIR/$FWROOT/*/$FWNAME.framework)
    local ARGS=
    for ARG in ${FRAMEWORKS[@]}; do
        ARGS+="-framework ${ARG} "
    done
    
    echo
    xcodebuild -create-xcframework $ARGS -output "$BUILD_DIR/$FWROOT/$FWNAME.xcframework"

    # These intermediate frameworks are silly, and not needed any more.
    find ${FWROOT} -mindepth 1 -maxdepth 1 -type d -not -name "$FWNAME.xcframework" -exec rm -rf '{}' \;
}


