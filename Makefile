.PHONY: all compile check shell release css sidecars browser-image computer-image computer-desktop-image acceptance run clean

all: compile

compile:
	rebar3 compile

check:
	./scripts/check.sh

shell:
	rebar3 shell --name muse@127.0.0.1

release:
	rebar3 release

run: release
	_build/default/rel/beamai_muse/bin/beamai_muse foreground

# Tailwind build for the aihtml UI (M6-1).
css:
	./scripts/build-css.sh

sidecars:
	cd sidecars/pdf && npm ci
	cd sidecars/mail && npm ci

# The per-user browser (BROWSER_ENABLED=true): Google Chrome on a virtual
# display with the bridge extension and the egress proxy (browser/).
browser-image:
	docker build -t muse-browser:local browser

computer-image:
	docker build -t openmuse-computer:local computer

# Desktop variant (COMPUTER_DESKTOP=true): Xvfb + openbox + offline GUI apps.
computer-desktop-image:
	docker build -t openmuse-computer-desktop:local -f computer/Dockerfile.desktop computer

# End-to-end checks against a real Chrome container and the Docker desktop.
acceptance: release
	./scripts/acceptance.sh

clean:
	rebar3 clean
