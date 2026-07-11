# Compile the RK3588 NPU device-tree overlay to a .dtbo.
#
# dtc is architecture-neutral, so this runs on the build host directly if dtc is
# present, or in a container otherwise:
#   make                       # needs dtc on PATH
#   make docker                # compile inside a debian container (no host dtc)
#
# The -@ flag emits a __symbols__ node so the overlay's &label targets resolve
# against the base device tree's symbol table at apply time.

DTSO := rk3588-turing-rk1-npu-rocket.dtso
DTBO := $(DTSO:.dtso=.dtbo)
DTC  ?= dtc
IMAGE ?= debian:trixie-slim

$(DTBO): $(DTSO)
	$(DTC) -@ -I dts -O dtb -o $@ $<
	@echo "built $@ ($$(stat -c%s $@) bytes)"

.PHONY: docker clean verify
docker:
	docker run --rm -v "$(CURDIR):/w" -w /w $(IMAGE) sh -c \
	  'apt-get update -qq && apt-get install -y -qq device-tree-compiler >/dev/null && \
	   dtc -@ -I dts -O dtb -o $(DTBO) $(DTSO) && echo "built $(DTBO)"'

verify: $(DTBO)
	fdtdump $(DTBO)

clean:
	rm -f $(DTBO)
