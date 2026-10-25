SHELL := /bin/bash
.DEFAULT_GOAL := app

.PHONY: app archive bootstrap ci dmg fetch fetch-mono fetch-native-python fetch-runtime fontlink-probe launcher \
	fetch-lgpl-sources fetch-seven-zip fetch-stdole fetch-swcli-runtime fetch-wine-source icon msi-helper package \
	printwindow-probe screen-readback-probe solidworks-app swcli-helper test theme-probe treeview-probe verify winemac

# SOLIDWORKS.app (the app users start) is packaged inside MacSW.app as Resources/SOLIDWORKS.app.zip,
# and MacSW installs it (docs/solidworks-app.md, section 4); MACSW_SKIP_SOLIDWORKS_APP=1 leaves it out.
# `make solidworks-app` builds a separate copy next to an existing build/app/MacSW.app.
MACSW_SKIP_SOLIDWORKS_APP ?= 0
export MACSW_SKIP_SOLIDWORKS_APP

# SWCLI is left out by default; MACSW_SKIP_SWCLI=0 packages it again.
MACSW_SKIP_SWCLI ?= 1
export MACSW_SKIP_SWCLI
SWCLI_PACKAGE_DEPS := $(if $(filter 1,$(MACSW_SKIP_SWCLI)),fetch-native-python,fetch-native-python swcli-helper fetch-swcli-runtime)

launcher:
	./macos/Bootstrap/build_bootstrap.sh

bootstrap: launcher

test:
	./scripts/test_bootstrap.sh

fetch:
	./scripts/fetch_dependencies.sh all

fetch-runtime:
	./scripts/fetch_dependencies.sh runtime

fetch-wine-source:
	./scripts/fetch_dependencies.sh wine-source

fetch-mono:
	./scripts/fetch_dependencies.sh mono

fetch-stdole:
	./scripts/fetch_dependencies.sh stdole

fetch-seven-zip:
	./scripts/fetch_dependencies.sh seven-zip

# The LGPL source archives that SOURCE.txt names (scripts/stage_source_release.sh copies them).
fetch-lgpl-sources:
	./scripts/fetch_dependencies.sh lgpl-sources

fetch-native-python:
	./scripts/fetch_dependencies.sh native-python

fetch-swcli-runtime:
	./scripts/fetch_dependencies.sh swcli-runtime

swcli-helper:
	./scripts/build_swcli_path_helper.sh

# The SpatialIOP MSI edit (docs/spatialiop-fix.md); package_app.sh builds it too.
msi-helper:
	./scripts/build_msi_spatialiop_helper.sh

# Optional developer diagnostic; not shipped or launched by the App.
theme-probe:
	bash ./scripts/build_wine_theme_probe.sh

treeview-probe:
	bash ./scripts/build_wine_treeview_probe.sh

printwindow-probe:
	bash ./scripts/build_wine_printwindow_probe.sh

fontlink-probe:
	bash ./scripts/build_wine_fontlink_probe.sh

screen-readback-probe:
	bash ./scripts/build_wine_screen_readback_probe.sh

icon:
	mkdir -p build/resources
	./scripts/generate_app_icon.swift build/resources

winemac: fetch-wine-source fetch-runtime
	./scripts/build_winemac.sh

package: launcher winemac icon fetch-runtime fetch-mono fetch-stdole fetch-seven-zip $(SWCLI_PACKAGE_DEPS)
	./scripts/package_app.sh

verify:
	./scripts/verify_app.sh

# Depends on launcher so that build/bootstrap/SOLIDWORKS is never an old build.
solidworks-app: launcher
	./scripts/package_solidworks_app.sh
	./scripts/verify_solidworks_app.sh

app: package
	./scripts/verify_app.sh

# The archive's SOLIDWORKS.app gets MacSW's icon, never one extracted from a local SLDWORKS.exe.
archive: export MACSW_SOLIDWORKS_EXE := none
archive: app
	mkdir -p build/archive
	source scripts/lib/config.sh; \
		rm -f -- "build/archive/MacSW-$${APP_RELEASE}-macOS.zip"; \
		ditto -c -k --sequesterRsrc --keepParent "build/app/MacSW.app" \
		"build/archive/MacSW-$${APP_RELEASE}-macOS.zip"

# The release disk image: build/dmg/MacSW-<release>.dmg and SHA256SUMS, signed with
# MACSW_SIGN_IDENTITY (scripts/package_dmg.sh, docs/packaging.md). Like the archive, its
# SOLIDWORKS.app gets MacSW's icon.
dmg: export MACSW_SOLIDWORKS_EXE := none
dmg: app
	./scripts/package_dmg.sh

ci: test archive
