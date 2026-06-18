HOLDIR ?= $(HOLBUILD_HOLDIR)
POLYC ?= polyc
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
VENDORED_HOL_FILES := $(shell sed 's|^|vendor/hol/|' vendor/hol/FILES)

.PHONY: all check-vendored-hol install uninstall test clean

all: bin/holbuild

check-vendored-hol:
	@test -s vendor/hol/REV || (echo "missing vendor/hol/REV" >&2; exit 1)
	@while IFS= read -r file; do \
		case "$$file" in ''|'#'*) continue ;; esac; \
		test -f "vendor/hol/$$file" || { echo "missing vendored HOL file: vendor/hol/$$file" >&2; exit 1; }; \
	done < vendor/hol/FILES

bin/holbuild: sml/holbuild-script.sml sml/hash.sml sml/version.sml sml/builtin_manifests.sml sml/cache_config.sml sml/git_cache.sml sml/file_lock.sml sml/hol_shared_cache.sml sml/analyser/analysis_protocol.sml sml/analyser/dependency_extract.sml sml/analyser/theory_span_extract.sml sml/analyser/proof_ir_extract.sml sml/analyser/analyser_main.sml sml/analyser/holbuild-hol-analyser-script.sml sml/project.sml sml/toolchain.sml sml/status.sml sml/generators.sml sml/source_index.sml sml/dependencies.sml sml/build_plan.sml sml/holbuild_runtime.sml sml/checkpoint_save_runtime.sml sml/proof_ir_types.sml sml/proof_ir.sml sml/proof_runtime.sml sml/theory_checkpoints.sml sml/checkpoint_store.sml sml/theory_diagnostics.sml sml/project_lock.sml sml/theory_spans.sml sml/build_exec.sml sml/cache.sml sml/commands.sml vendor/hol/REV vendor/hol/FILES $(VENDORED_HOL_FILES) | check-vendored-hol
	@mkdir -p bin
	$(POLYC) -o $@ sml/holbuild-script.sml

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
