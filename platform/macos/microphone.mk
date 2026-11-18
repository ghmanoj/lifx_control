MIC_PLIST = platform/macos/MicrophoneInfo.plist
MIC_CFLAGS = -fblocks
MIC_LIBS = -framework AudioToolbox -framework AVFoundation -lobjc \
           -Wl,-sectcreate,__TEXT,__info_plist,$(MIC_PLIST)
