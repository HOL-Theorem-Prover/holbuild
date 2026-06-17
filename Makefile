HOL_SOURCE ?=
HOLDIR ?= $(HOLBUILD_HOLDIR)
POLYC ?= polyc
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
HOL_SOURCE_PIN := $(shell tr -d '[:space:]' < PINS/hol.txt)

.PHONY: all check-hol-source install uninstall test clean

all: bin/holbuild

check-hol-source:
	@test -n "$(HOL_SOURCE)" || (echo "Set HOL_SOURCE=/path/to/HOL source checkout. This checkout does not need to be built." >&2; exit 1)
	@test -d "$(HOL_SOURCE)/.git" || (echo "HOL_SOURCE must be a HOL git checkout: $(HOL_SOURCE)" >&2; exit 1)
	@test "$$(git -C "$(HOL_SOURCE)" rev-parse HEAD)" = "$(HOL_SOURCE_PIN)" || (echo "HOL_SOURCE is at $$(git -C "$(HOL_SOURCE)" rev-parse HEAD), but holbuild is pinned to $(HOL_SOURCE_PIN) from PINS/hol.txt" >&2; exit 1)

bin/holbuild: sml/holbuild-script.sml sml/hash.sml sml/version.sml sml/builtin_manifests.sml sml/git_cache.sml sml/file_lock.sml sml/hol_shared_cache.sml sml/analyser/analysis_protocol.sml sml/analyser/dependency_extract.sml sml/analyser/theory_span_extract.sml sml/analyser/proof_ir_extract.sml sml/analyser/analyser_main.sml sml/analyser/holbuild-hol-analyser-script.sml sml/project.sml sml/toolchain.sml sml/status.sml sml/generators.sml sml/source_index.sml sml/dependencies.sml sml/build_plan.sml sml/holbuild_runtime.sml sml/checkpoint_save_runtime.sml sml/proof_ir_types.sml sml/proof_ir.sml sml/proof_runtime.sml sml/theory_checkpoints.sml sml/checkpoint_store.sml sml/theory_diagnostics.sml sml/project_lock.sml sml/theory_spans.sml sml/build_exec.sml sml/cache.sml sml/commands.sml PINS/hol.txt | check-hol-source
	@mkdir -p bin
	HOL_SOURCE="$(HOL_SOURCE)" $(POLYC) -o $@ sml/holbuild-script.sml

install: bin/holbuild
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 bin/holbuild "$(DESTDIR)$(BINDIR)/holbuild"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/holbuild"

test: bin/holbuild
	HOLDIR="$(HOLDIR)" tests/run.sh

clean:
	rm -f bin/holbuild
	rmdir bin 2>/dev/null || true
