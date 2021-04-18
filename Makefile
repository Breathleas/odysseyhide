BUNDLE := org.coolstar.odyssey

.PHONY: all clean

all: clean
	$(MAKE) -C migrationsupport clean all
	$(MAKE) -C amfidebilitate clean all
	cd Odyssey/resources && tar -xf basebinaries.tar
	rm -f Odyssey/resources/{amfidebilitate,migration,basebinaries.tar}
	cp {amfidebilitate,migrationsupport}/bin/* Odyssey/resources
	cd Odyssey/resources && tar -cf basebinaries.tar amfidebilitate jailbreakd jbexec migration pspawn_payload-stg2.dylib pspawn_payload.dylib
	rm -f Odyssey/resources/{amfidebilitate,jailbreakd,jbexec,migration,*.dylib}
	xcodebuild clean build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO PRODUCT_BUNDLE_IDENTIFIER="$(BUNDLE)" -sdk iphoneos -scheme Odyssey -configuration Release -derivedDataPath build
	ln -sf build/Build/Products/Release-iphoneos Payload
	rm -rf Payload/Odyssey.app/Frameworks
	zip -r9 Odyssey.ipa Payload/Odyssey.app

clean:
	rm -rf build Payload Odyssey.ipa
	$(MAKE) -C migrationsupport clean
	$(MAKE) -C amfidebilitate clean
