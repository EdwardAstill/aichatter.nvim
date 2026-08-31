.PHONY: test
test:
	TEST="$(TEST)" nvim --headless --clean -u tests/minimal_init.lua \
		-c "lua dofile('tests/run.lua')"
