.PHONY: test lint fmt

test:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

lint:
	selene lua/
	stylua --check lua/ tests/

fmt:
	stylua lua/ tests/
