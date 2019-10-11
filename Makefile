
default: wasi_http.html

.PHONY: setup
setup:
	npm install --save-dev @marp-team/marp-cli

wasi_http.html: wasi_http.md
	npx marp wasi_http.md -o wasi_http.html


.PHONY: preview
preview:
	npx marp -p wasi_http.md
