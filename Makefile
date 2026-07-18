HOLDIR ?= $(HOLBUILD_HOLDIR)
HOLBUILD_KEEP_TEST_LOGS ?=
POLYC ?= polyc
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/holbuild
VENDORED_HOL_FILES := $(shell sed 's|^|vendor/hol/|' vendor/hol/FILES)
VENDORED_SHA256_FILES := $(wildcard vendor/sml-sha256/lib/*.sig vendor/sml-sha256/lib/*.sml) vendor/sml-sha256/LICENSE vendor/sml-sha256/AUTHORS vendor/sml-sha256/README.holbuild

.PHONY: all check-vendored-hol install uninstall test golden-key-dump-check clean

all: bin/holbuild

GOLDEN_KEY_BASELINE := tests/golden/key-dumps

golden-key-dump-check: bin/holbuild
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	HOLDIR="$(HOLDIR)" HOLBUILD_HOLDIR="$(HOLBUILD_HOLDIR)" tests/golden-key-dump.sh capture "$$tmp"; \
	tests/golden-key-dump.sh diff "$(GOLDEN_KEY_BASELINE)" "$$tmp";

check-vendored-hol:
	@test -s vendor/hol/REV || (echo "missing vendor/hol/REV" >&2; exit 1)
	@while IFS= read -r file; do \
		case "$$file" in ''|'#'*) continue ;; esac; \
		test -f "vendor/hol/$$file" || { echo "missing vendored HOL file: vendor/hol/$$file" >&2; exit 1; }; \
	done < vendor/hol/FILES

bin/holbuild: sml/holbuild-script.sml sml/string_hash.sml sml/hash.sml sml/stat_cache.sml sml/version.sml sml/builtin_manifests.sml sml/hol_source_manifest.sml sml/cache_config.sml sml/remote_cache_config.sml sml/git_cache.sml sml/file_lock.sml sml/cache_backend.sml sml/fs_cache_backend.sml sml/cache_transfer.sml sml/remote_cache.sml sml/tar_archive.sml sml/cache_archive.sml sml/toolchain_archive.sml sml/hol_shared_cache.sml sml/manifest_util.sml sml/package_definition.sml sml/package_provenance.sml sml/local_config.sml sml/project_graph.sml sml/analyser/analysis_protocol.sml sml/analyser/dependency_extract.sml sml/analyser/theory_span_extract.sml sml/analyser/proof_ir_extract.sml sml/analyser/analyser_main.sml sml/analyser/holbuild-hol-analyser-script.sml sml/project.sml sml/toolchain.sml sml/status.sml sml/generators.sml sml/package_prepare.sml sml/source_index.sml sml/package_component.sml sml/dependencies.sml sml/component_provider.sml sml/build_plan.sml sml/holbuild_runtime.sml sml/checkpoint_save_runtime.sml sml/proof_ir_types.sml sml/proof_ir.sml sml/proof_runtime.sml sml/theory_checkpoints.sml sml/checkpoint_store.sml sml/theory_diagnostics.sml sml/project_lock.sml sml/theory_spans.sml sml/build_exec.sml sml/cache.sml sml/watch.sml sml/commands.sml vendor/hol/REV vendor/hol/FILES $(VENDORED_HOL_FILES) $(VENDORED_SHA256_FILES) | check-vendored-hol
bin/holbuild: sml/process_group.sml
	@mkdir -p bin
	$(POLYC) -o $@ sml/holbuild-script.sml

install: bin/holbuild
	install -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(DATADIR)/copyrights"
	install -m 755 bin/holbuild "$(DESTDIR)$(BINDIR)/holbuild"
	install -m 644 vendor/hol/copyrights/smlnj.txt "$(DESTDIR)$(DATADIR)/copyrights/smlnj.txt"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/holbuild" "$(DESTDIR)$(DATADIR)/copyrights/smlnj.txt"

test: bin/holbuild
	HOLBUILD_KEEP_TEST_LOGS="$(HOLBUILD_KEEP_TEST_LOGS)" HOLDIR="$(HOLDIR)" tests/run.sh $(TESTS)
ifeq ($(strip $(TESTS)),)
	$(MAKE) golden-key-dump-check
endif

clean:
	rm -f bin/holbuild
	rmdir bin 2>/dev/null || true
