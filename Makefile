ax-helper:
	npm run build:native

ax-demo:
	@echo "Build the project-local helper with: make ax-helper"
	@echo "Helper path: dist/native/computer-use-host"
	@echo "Protocol version: dist/native/computer-use-host --protocol-version"
