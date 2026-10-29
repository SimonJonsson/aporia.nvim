.PHONY: test test-file lint fmt

test:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

# one spec in isolation: make test-file F=tests/slash_spec.lua
# (PlenaryBustedFile alone would load the user's nvim config)
test-file:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory $(F) { minimal_init = 'tests/minimal_init.lua' }"

lint:
	selene lua/
	stylua --check lua/ tests/

fmt:
	stylua lua/ tests/
