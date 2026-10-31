FORGE ?= forge
PYTHON ?= python3

.PHONY: build test gas consumer fmt clean

build:
	$(FORGE) build

test:
	$(FORGE) test

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
