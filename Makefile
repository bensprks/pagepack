FORGE ?= forge
PYTHON ?= python3

.PHONY: build test test-fast gas consumer fmt clean

build:
	$(FORGE) build

test:
	$(FORGE) test

# Compiles with Solar, which builds about 10x faster than solc, for a quick loop while editing.
# Its code generation is experimental, so CI, snapshots/ and the published numbers stay on solc.
# Builds into its own out/ and cache/ so switching back to solc doesn't recompile, and leaves
# snapshots/ alone.
test-fast:
	$(FORGE) test --use solar --out out/solar --cache-path cache/solar --gas-snapshot-emit false

# Runs the benchmarks (each scenario is its own cold transaction) and prints the comparison tables.
gas:
	$(FORGE) test --match-path 'test/gas/*'
	$(PYTHON) test/gas/report.py

# Builds a fresh project that installs pagepack as the README describes.
consumer:
	FORGE=$(FORGE) ./scripts/check-consumer.sh

# forge fmt only covers src/ and test/ by default.
fmt:
	$(FORGE) fmt
	$(FORGE) fmt examples

clean:
	$(FORGE) clean
