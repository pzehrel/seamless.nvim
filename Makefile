.PHONY: test format format-check lint check

test:
	nvim --headless -u tests/minimal_init.lua -c "luafile tests/run.lua"

format:
	stylua lua tests

format-check:
	stylua --check lua tests

lint:
	luacheck lua tests

check: format-check lint test
