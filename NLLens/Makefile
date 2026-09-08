# Convenience targets. `make project` needs XcodeGen:
#   brew install xcodegen

.PHONY: project test clean open smoke

project: Secrets.xcconfig
	xcodegen generate

Secrets.xcconfig:
	cp Secrets.example.xcconfig Secrets.xcconfig

test:
	swift test

# Verifies your Nebius key and model with the exact request the app sends.
#   NEBIUS_API_KEY=... make smoke
smoke:
	./scripts/smoke-test.sh

clean:
	rm -rf .build NLLens.xcodeproj

open: project
	open NLLens.xcodeproj
