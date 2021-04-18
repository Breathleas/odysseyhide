#
# Sample makefile for bash loadable builtin development
#
# Copyright (C) 2015 Free Software Foundation, Inc.     

#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

PACKAGE = bash
VERSION = 5.0-release

PACKAGE_NAME = bash
PACKAGE_VERSION = 5.0-release

# Include some boilerplate Gnu makefile definitions.
prefix = /usr

exec_prefix = ${prefix}
bindir = ${exec_prefix}/bin
libdir = ${exec_prefix}/lib
infodir = ${datarootdir}/info
includedir = ${prefix}/include

datarootdir = ${prefix}/share

loadablesdir = ${libdir}/bash
headersdir = $(includedir)/$(PACKAGE_NAME)

topdir = ../..
BUILD_DIR = /Users/haydenseay/GitHub/Procursus/build_work/iphoneos-arm64/1600/bash
srcdir = .


# Support an alternate destination root directory for package building
DESTDIR =

INSTALL = /usr/bin/install -c
INSTALL_PROGRAM = ${INSTALL}
INSTALL_SCRIPT = ${INSTALL}
INSTALL_DATA = ${INSTALL} -m 644
INSTALLMODE= -m 0755


CC = gcc
RM = rm -f

SHELL = /bin/sh

host_os = darwin
host_cpu = aarch64
host_vendor = apple

CFLAGS = -O2 -arch arm64  -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS14.0.sdk -miphoneos-version-min=13.0 -isystem /Users/haydenseay/GitHub/Procursus/build_base/iphoneos-arm64/1600/usr/include -isystem /Users/haydenseay/GitHub/Procursus/build_base/iphoneos-arm64/1600/usr/local/include -F/Users/haydenseay/GitHub/Procursus/build_base/iphoneos-arm64/1600/System/Library/Frameworks -DSSH_SOURCE_BASHRC -Wno-parentheses -Wno-format-security
LOCAL_CFLAGS = -DMACOSX
DEFS = -DHAVE_CONFIG_H
LOCAL_DEFS = -DSHELL

CPPFLAGS = -O2 -arch arm64 -miphoneos-version-min=13.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS14.0.sdk -isystem /Users/haydenseay/GitHub/Procursus/build_base/iphoneos-arm64/1600/usr/include -isystem /Users/haydenseay/GitHub/Procursus/build_base/iphoneos-arm64/1600/usr/local/include

BASHINCDIR = ${topdir}/include

SUPPORT_SRC = $(topdir)/support/

LIBBUILD = ${BUILD_DIR}/lib

INTL_LIBSRC = ${topdir}/lib/intl
INTL_BUILDDIR = ${LIBBUILD}/intl
INTL_INC = 
LIBINTL_H = 

CCFLAGS = $(DEFS) $(LOCAL_DEFS) $(LOCAL_CFLAGS) $(CFLAGS)

#
# These values are generated for configure by ${topdir}/support/shobj-conf.
# If your system is not supported by that script, but includes facilities for
# dynamic loading of shared objects, please update the script and send the
# changes to bash-maintainers@gnu.org.
#
SHOBJ_CC = gcc
SHOBJ_CFLAGS = -fno-common
SHOBJ_LD = ${CC}
SHOBJ_LDFLAGS = -dynamiclib -dynamic -undefined dynamic_lookup  -O2 -arch arm64  -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS14.0.sdk -miphoneos-version-min=13.0 -L/Users/haydenseay/GitHub/Procursus/build_base/iphoneos-arm64/1600/usr/lib -L/Users/haydenseay/GitHub/Procursus/build_base/iphoneos-arm64/1600/usr/local/lib -F/Users/haydenseay/GitHub/Procursus/build_base/iphoneos-arm64/1600/System/Library/Frameworks
SHOBJ_XLDFLAGS = 
SHOBJ_LIBS = 
SHOBJ_STATUS = supported

INC = -I$(headersdir) -I$(headersdir)/include -I$(headersdir)/builtins

.c.o:
	$(SHOBJ_CC) $(SHOBJ_CFLAGS) $(CCFLAGS) $(INC) -c -o $@ $<

all:	example

example:	example.o
	$(SHOBJ_LD) $(SHOBJ_LDFLAGS) $(SHOBJ_XLDFLAGS) -o $@ example.o $(SHOBJ_LIBS)

example.o: example.c
