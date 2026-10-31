FORGE ?= forge
PYTHON ?= python3

.PHONY: build test gas fmt clean

build:
	$(FORGE) build

test:
	$(FORGE) test

# Runs the benchmarks (each scenario is its own cold transaction) and prints the comparison table.
gas:
	$(FORGE) test --match-path 'test/gas/*'
	$(PYTHON) test/gas/report.py

fmt:
	$(FORGE) fmt

clean:
	$(FORGE) clean
