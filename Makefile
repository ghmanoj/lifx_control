CFLAGS ?= -O2
C_STANDARD = -std=c11 -Wall -Wextra -Wpedantic
BIN = build
WITH_MICROPHONE ?= 0
OS ?= $(shell uname -s)
PROGRAMS = $(BIN)/lifx-control
CONTROLLER_SRC = main.c

ifeq ($(WITH_MICROPHONE),1)
ifeq ($(OS),Darwin)
PLATFORM = platform/macos
else ifeq ($(OS),Linux)
PLATFORM = platform/linux
else
$(error Microphone capture is available on macOS and Linux)
endif
include $(PLATFORM)/microphone.mk
PROGRAMS += $(BIN)/lifx-microphone
CONTROLLER_SRC += $(PLATFORM)/executable_path.c
CONTROLLER_HEADERS = platform/executable_path.h
else ifneq ($(WITH_MICROPHONE),0)
$(error WITH_MICROPHONE must be 0 or 1)
endif

CONFIG = $(BIN)/.config-$(OS)-mic$(WITH_MICROPHONE)
.PHONY: all test clean
all: $(PROGRAMS)

$(BIN):
	mkdir -p $@

# Switching modes must rebuild the controller even when the sources are unchanged.
$(CONFIG): | $(BIN)
	$(RM) $(BIN)/.config-*-mic* $(BIN)/lifx-microphone
	touch $@

$(BIN)/lifx-control: $(CONTROLLER_SRC) $(CONTROLLER_HEADERS) $(CONFIG) Makefile
	$(CC) $(CPPFLAGS) $(C_STANDARD) $(CFLAGS) -DWITH_MICROPHONE=$(WITH_MICROPHONE) \
		$(LDFLAGS) -o $@ $(CONTROLLER_SRC) $(LDLIBS) -lm

ifeq ($(WITH_MICROPHONE),1)
$(BIN)/lifx-microphone: microphone.c microphone.h $(PLATFORM)/microphone.c $(MIC_PLIST) $(CONFIG) Makefile $(PLATFORM)/microphone.mk
	$(CC) $(CPPFLAGS) -I. $(C_STANDARD) $(CFLAGS) $(MIC_CFLAGS) $(LDFLAGS) \
		-o $@ microphone.c $(PLATFORM)/microphone.c $(MIC_LIBS) $(LDLIBS) -lm
endif

test: all
	python3 test_cli.py
ifeq ($(WITH_MICROPHONE),1)
	$(BIN)/lifx-microphone --self-test
endif

clean:
	$(RM) $(BIN)/lifx-control $(BIN)/lifx-microphone $(BIN)/.config-*-mic*
