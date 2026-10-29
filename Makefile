.PHONY: test test-file test-rust backend lint fmt

test:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

# one spec in isolation: make test-file F=tests/slash_spec.lua
# (PlenaryBustedFile alone would load the user's nvim config)
test-file:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory $(F) { minimal_init = 'tests/minimal_init.lua' }"

test-rust:
	cd backend && cargo test

# the binary the plugin starts; lazy.nvim users can set build = "make backend"
backend:
	cd backend && cargo build --release

lint:
	selene lua/
	stylua --check lua/ tests/
	cd backend && cargo clippy --all-targets -- -D warnings && cargo fmt --check

fmt:
	stylua lua/ tests/
	cd backend && cargo fmt
