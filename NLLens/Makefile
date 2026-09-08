# Convenience targets. `make project` needs XcodeGen:
#   brew install xcodegen

.PHONY: project test clean open

project: Secrets.xcconfig
	xcodegen generate

Secrets.xcconfig:
	cp Secrets.example.xcconfig Secrets.xcconfig

test:
	swift test

clean:
	rm -rf .build NLLens.xcodeproj

open: project
	open NLLens.xcodeproj
