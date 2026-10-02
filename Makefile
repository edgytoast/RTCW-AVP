# RTCW visionOS — common commands. `make help` lists them.
.PHONY: help setup config headset headset-debug install sim build angle project vr flat headset-log

help:
	@echo "make setup          one-time setup on a new Mac (prerequisites, config, ANGLE, project)"
	@echo "make config         (re)detect signing team and game data location (config.local)"
	@echo "make headset        build Release, install on Vision Pro, launch (copies game data if missing)"
	@echo "make vr / make flat launch straight into VR or flat mode on the Vision Pro"
	@echo "make install        same, without launching"
	@echo "make headset-debug  Debug build on Vision Pro"
	@echo "make sim            run 60 s in the visionOS Simulator (log: build/logs/sim-run.log)"
	@echo "make build          compile-check device + simulator"
	@echo "make project        regenerate the Xcode project"
	@echo "make angle          (re)build ANGLE static libs"
	@echo "make headset-log    fetch the engine console log from the Vision Pro"

setup:
	@bash scripts/setup.sh
config:
	@rm -f config.local && bash -c 'source scripts/config.sh && vos_config --interactive'
headset:
	@bash scripts/device-run.sh
install:
	@bash scripts/device-run.sh --no-launch
vr:
	@bash scripts/device-run.sh -vr +set com_introplayed 1 +set in_padDebug 1
flat:
	@bash scripts/device-run.sh -flat +set com_introplayed 1 +set in_padDebug 1
headset-debug:
	@bash scripts/device-run.sh --debug
sim:
	@bash scripts/build.sh sim && SHOT=build/logs/sim.png bash scripts/sim-run.sh 60 -flat +set com_introplayed 1
build:
	@bash scripts/build.sh device && bash scripts/build.sh sim
project:
	@bash scripts/gen-project.sh
angle:
	@bash scripts/build-angle.sh
headset-log:
	@bash scripts/device-log.sh
