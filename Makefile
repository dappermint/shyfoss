APP = build/ShyFoss.app

$(APP): main.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	swiftc -O -o $(APP)/Contents/MacOS/ShyFoss main.swift
	cp Info.plist $(APP)/Contents/
	codesign -s - -f $(APP)

run: $(APP)
	open $(APP)

test: $(APP)
	$(APP)/Contents/MacOS/ShyFoss --selftest

clean:
	rm -rf build
