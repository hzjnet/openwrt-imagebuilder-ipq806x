# Makefile for OpenWrt
#
# Copyright (C) 2007-2015 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

TOPDIR:=${CURDIR}
LC_ALL:=C
LANG:=C
export TOPDIR LC_ALL LANG
export OPENWRT_VERBOSE=s
all: help

include $(TOPDIR)/include/host.mk

ifneq ($(OPENWRT_BUILD),1)
  override OPENWRT_BUILD=1
  export OPENWRT_BUILD
endif

include rules.mk
include $(INCLUDE_DIR)/debug.mk
include $(INCLUDE_DIR)/depends.mk

include $(INCLUDE_DIR)/version.mk
export REVISION

define Helptext
Available Commands:
	help:	This help text
	info:	Show a list of available target profiles
	clean:	Remove images and temporary build files
	image:	Build an image (see below for more information).

Building images:
	By default 'make image' will create an image with the default
	target profile and package set. You can use the following parameters
	to change that:

	make image PROFILE="<profilename>" # override the default target profile
	make image PACKAGES="<pkg1> [<pkg2> [<pkg3> ...]]" # include extra packages
	make image FILES="<path>" # include extra files from <path>
	make image BIN_DIR="<path>" # alternative output directory for the images

endef
$(eval $(call shexport,Helptext))

help: FORCE
	echo "$$$(call shvar,Helptext)"


# override variables from rules.mk
PACKAGE_DIR:=$(TOPDIR)/packages
OPKG:= \
  IPKG_NO_SCRIPT=1 \
  IPKG_TMP="$(TMP_DIR)/ipkgtmp" \
  IPKG_INSTROOT="$(TARGET_DIR)" \
  IPKG_CONF_DIR="$(TMP_DIR)" \
  IPKG_OFFLINE_ROOT="$(TARGET_DIR)" \
  $(STAGING_DIR_HOST)/bin/opkg \
	-f $(TOPDIR)/repositories.conf \
	--force-depends \
	--force-overwrite \
	--force-postinstall \
	--cache $(DL_DIR) \
	--offline-root $(TARGET_DIR) \
	--add-dest root:/ \
	--add-arch all:100 \
	--add-arch $(ARCH_PACKAGES):200

define Profile
  $(eval $(call Profile/Default))
  $(eval $(call Profile/$(1)))
  ifeq ($(USER_PROFILE),)
    USER_PROFILE:=$(1)
  endif
  $(1)_NAME:=$(NAME)
  $(1)_PACKAGES:=$(PACKAGES)
  PROFILE_NAMES += $(1)
  PROFILE_LIST += \
  	echo '$(1):'; [ -z '$(NAME)' ] || echo '	$(NAME)'; echo '	Packages: $(PACKAGES)';
endef

include $(INCLUDE_DIR)/target.mk

_call_info: FORCE
	echo 'Current Target: "$(BOARD)$(if $(SUBTARGET), ($(BOARDNAME)))"'
	echo 'Default Packages: $(DEFAULT_PACKAGES)'
	echo 'Available Profiles:'
	echo; $(PROFILE_LIST)

REPO_URL:="http://www.gl-inet.com/openwrt"
PACKAGE_SUBDIRS:=$(foreach dir,$(PACKAGE_DIR)/*,$(shell find $(dir) -type d -print))
BUILD_PACKAGES:=$(sort $(DEFAULT_PACKAGES) $(USER_PACKAGES) $($(USER_PROFILE)_PACKAGES) kernel)
# "-pkgname" in the package list means remove "pkgname" from the package list
BUILD_PACKAGES:=$(filter-out $(filter -%,$(BUILD_PACKAGES)) $(patsubst -%,%,$(filter -%,$(BUILD_PACKAGES))),$(BUILD_PACKAGES))
PACKAGES:=

_call_image:
	echo 'Building images for $(BOARD)$(if $($(USER_PROFILE)_NAME), - $($(USER_PROFILE)_NAME))'
	echo 'Packages: $(BUILD_PACKAGES)'
	echo
	rm -rf $(TARGET_DIR)
	mkdir -p $(TARGET_DIR) $(BIN_DIR) $(TMP_DIR) $(DL_DIR)
	if [ ! -f "$(PACKAGE_DIR)/Packages" ] || [ ! -f "$(PACKAGE_DIR)/Packages.gz" ] || [ "`find $(PACKAGE_DIR) -cnewer $(PACKAGE_DIR)/Packages.gz -not -name "*.sig"`" ]; then \
		echo "Package list missing or not up-to-date, generating it.";\
		$(MAKE) package_index; \
	else \
		mkdir -p $(TARGET_DIR)/tmp; \
		$(OPKG) update || true; \
	fi
	$(MAKE) package_install
ifneq ($(REMOVE_PACKAGES),)
	$(MAKE) package_remove
endif
ifneq ($(VERSION),)
	$(MAKE) prepare_files
endif
ifneq ($(USER_FILES),)
	$(MAKE) copy_files
endif
	$(MAKE) package_postinst
	$(MAKE) build_image

package_index: FORCE
	@echo
	@echo Building package index...
	@mkdir -p $(TMP_DIR) $(TARGET_DIR)/tmp
	@for d in $(PACKAGE_SUBDIRS); do ( \
		cd $$d || continue; \
		$(SCRIPT_DIR)/ipkg-make-index.sh . 2>&1 > Packages; \
			gzip -9c Packages > Packages.gz \
	) >/dev/null 2>/dev/null; done
	(cd $(PACKAGE_DIR); $(SCRIPT_DIR)/ipkg-make-index.sh . > Packages && \
		gzip -9c Packages > Packages.gz \
	) >/dev/null 2>/dev/null
ifdef CONFIG_SIGNED_PACKAGES
	@echo Signing package index...
	@for d in $(PACKAGE_SUBDIRS); do ( \
		[ -d $$d ] && \
			cd $$d || continue; \
		$(STAGING_DIR_HOST)/bin/usign -S -m Packages -s $(BUILD_KEY); \
	); done
endif
	$(OPKG) update || true

package_install: FORCE
	@echo
	@echo Installing packages...
	$(OPKG) install $(firstword $(wildcard $(PACKAGE_DIR)/libc_*.ipk $(PACKAGE_DIR)/base/libc_*.ipk))
	$(OPKG) install $(firstword $(wildcard $(PACKAGE_DIR)/kernel_*.ipk $(PACKAGE_DIR)/base/kernel_*.ipk))
	$(OPKG) install $(BUILD_PACKAGES)
	rm -f $(TARGET_DIR)/usr/lib/opkg/lists/*

package_remove: FORCE
	@echo
	@echo Removing packages...
	$(OPKG) remove $(REMOVE_PACKAGES)
	rm -f $(TARGET_DIR)/usr/lib/opkg/lists/*

define FeedSources
@( \
	$(foreach PKG,$(notdir $(PACKAGE_SUBDIRS)),echo "src/gz openwrt_$(PKG) $(REPO_URL)/$(BOARD)/$(VERSION)/$(PKG)";) \
) > $(1)
endef

prepare_files: FORCE
	@mkdir -p $(TARGET_DIR)/etc
	@mkdir -p $(TARGET_DIR)/etc/opkg
	@echo "$(VERSION)" > $(TARGET_DIR)/etc/glversion
	$(call FeedSources,$(TARGET_DIR)/etc/opkg/distfeeds.conf)

copy_files: FORCE
	@echo
	@echo Copying extra files
	@$(call file_copy,$(USER_FILES)/*,$(TARGET_DIR)/)

package_postinst: FORCE
	@echo
	@echo Cleaning up
	@rm -f $(TARGET_DIR)/tmp/opkg.lock
	@echo
	@echo Activating init scripts
	@mkdir -p $(TARGET_DIR)/etc/rc.d
	@( \
		cd $(TARGET_DIR); \
		for script in ./usr/lib/opkg/info/*.postinst; do \
			IPKG_INSTROOT=$(TARGET_DIR) $$(which bash) $$script; \
		done || true \
	)
	rm -f $(TARGET_DIR)/usr/lib/opkg/info/*.postinst
	$(if $(CONFIG_CLEAN_IPKG),rm -rf $(TARGET_DIR)/usr/lib/opkg)

build_image: FORCE
	@echo
	@echo Building images...
	$(NO_TRACE_MAKE) -C target/linux/$(BOARD)/image install TARGET_BUILD=1 IB=1 \
		$(if $(USER_PROFILE),PROFILE="$(USER_PROFILE)")

clean:
	rm -rf $(TMP_DIR) $(DL_DIR) $(TARGET_DIR) $(BIN_DIR)

si: FORCE
	tar xf single_img_dir_simple.tar.gz
	rm -f $(TOPDIR)/single_img_dir/IPQ4019.ILQ.5.0/common/build/ipq/openwrt*
	rm -f $(TOPDIR)/single_img_dir/IPQ4019.ILQ.5.0/common/build/bin/*
	rm -f $(TOPDIR)/single_img_dir/IPQ4019.ILQ.5.0/common/build/*.log
	cp $(TOPDIR)/bin/ipq806x/openwrt* $(TOPDIR)/single_img_dir/IPQ4019.ILQ.5.0/common/build/ipq
	cp $(TOPDIR)/single_img_dir/IPQ4019.ILQ.5.0/common/build/*-flash.conf $(TOPDIR)/single_img_dir/IPQ4019.ILQ.5.0/common/build/ipq
	cd single_img_dir/IPQ4019.ILQ.5.0/common/build; \
	python pack.py -t nor -B -F boardconfig_premium -o ../../../nor-ipq40xx-single.img ./ipq

info:
	(unset PROFILE FILES PACKAGES MAKEFLAGS; $(MAKE) -s _call_info)

image:
ifneq ($(PROFILE),)
  ifeq ($(filter $(PROFILE),$(PROFILE_NAMES)),)
	@echo 'Profile "$(PROFILE)" does not exist!'
	@echo 'Use "make info" to get a list of available profile names.'
	@exit 1
  endif
endif
	(unset PROFILE FILES PACKAGES MAKEFLAGS; \
	$(MAKE) _call_image \
		$(if $(PROFILE),USER_PROFILE="$(PROFILE)") \
		$(if $(FILES),USER_FILES="$(FILES)") \
		$(if $(PACKAGES),USER_PACKAGES="$(PACKAGES)") \
		$(if $(BIN_DIR),BIN_DIR="$(BIN_DIR)"))

.SILENT: help info image

