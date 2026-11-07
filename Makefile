HOLDIR ?= $(HOLBUILD_HOLDIR)
HOLBUILD_KEEP_TEST_LOGS ?=
POLYC ?= polyc
POLY ?= $(dir $(realpath $(shell command -v $(POLYC))))poly
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/holbuild
VENDORED_HOL_FILES := $(shell sed 's|^|vendor/hol/|' vendor/hol/FILES)
RUNTIME_SOURCES := sml/checkpoint_save_runtime.sml sml/holbuild_runtime.sml \
	sml/fingerprint_runtime.sml sml/proof_runtime.sml sml/tactic_compat_runtime.sml sml/diagnostic_limits.sml sml/sha256.sml \
	sml/spawn.sml sml/hash.sml sml/proof_ir_types.sml sml/proof_ir.sml \
	$(wildcard sml/analyser/*.sml)

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

bin/holbuild: sml/holbuild-script.sml sml/sha256.sml sml/spawn.sml sml/hash.sml sml/temp_path.sml sml/remove_tree.sml sml/stat_cache.sml sml/version.sml sml/diagnostic_limits.sml sml/suggest.sml sml/builtin_manifests.sml sml/hol_source_manifest.sml sml/cache_config.sml sml/offline.sml sml/http.sml sml/remote_cache_config.sml sml/cache_discovery.sml sml/git_cache.sml sml/file_lock.sml sml/cache_backend.sml sml/theory_cache_manifest.sml sml/fs_cache_backend.sml sml/cache_transfer.sml sml/remote_cache.sml sml/tar_archive.sml sml/cache_archive.sml sml/toolchain_archive.sml sml/hol_shared_cache.sml sml/manifest_util.sml sml/package_definition.sml sml/package_provenance.sml sml/local_config.sml sml/project_graph.sml sml/analyser/analysis_protocol.sml sml/analyser/dependency_extract.sml sml/analyser/theory_span_extract.sml sml/analyser/proof_step_plan_adapter_legacy.sml sml/analyser/proof_step_plan_adapter_shared.sml sml/analyser/tactic_parse_capabilities.sml sml/analyser/tactic_parse_adapter_legacy.sml sml/analyser/tactic_parse_adapter_token_spans.sml sml/analyser/proof_ir_extract.sml sml/analyser/analyser_main.sml sml/analyser/holbuild-hol-analyser-script.sml sml/project.sml sml/toolchain.sml sml/status.sml sml/machine_memory.sml sml/generators.sml sml/package_prepare.sml sml/source_index.sml sml/package_component.sml sml/dependencies.sml sml/component_provider.sml sml/build_plan.sml sml/plan_record.sml sml/holbuild_runtime.sml sml/checkpoint_save_runtime.sml sml/proof_ir_types.sml sml/proof_ir.sml sml/tactic_compat_runtime.sml sml/proof_runtime.sml sml/theory_checkpoints.sml sml/checkpoint_store.sml sml/theory_diagnostics.sml sml/project_lock.sml sml/theory_spans.sml sml/build_exec.sml sml/cache.sml sml/watch.sml sml/remote_exec.sml sml/commands.sml vendor/hol/REV vendor/hol/FILES $(VENDORED_HOL_FILES) | check-vendored-hol
# polyc's own compile step, but with one GC thread: Poly/ML 5.9.2 can abort
# with more than ~100 GC threads (polyml/polyml#327). polyc then links.
bin/holbuild: sml/process_group.sml sml/tactic_timeout_policy.sml
	@mkdir -p bin
	echo 'val () = use "sml/holbuild-script.sml"; val () = PolyML.export("$@.o", main);' | \
		HOLBUILD_COMPILE_DATADIR="$(abspath $(DATADIR))" $(POLY) -q --error-exit --gcthreads=1
	$(POLYC) -o $@ $@.o
	rm -f $@.o

install: bin/holbuild
# Custom layouts can't locate their data relative to the executable. Re-export
# with this install's DATADIR even if an earlier make used different options.
ifneq ($(abspath $(DATADIR)),$(abspath $(BINDIR)/../share/holbuild))
	$(MAKE) -B bin/holbuild
endif
	install -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(DATADIR)/copyrights"
	install -m 755 bin/holbuild "$(DESTDIR)$(BINDIR)/holbuild"
	install -m 644 vendor/hol/copyrights/smlnj.txt "$(DESTDIR)$(DATADIR)/copyrights/smlnj.txt"
	install -m 644 LICENSE "$(DESTDIR)$(DATADIR)/LICENSE"
	@for file in $(RUNTIME_SOURCES); do \
		install -d "$(DESTDIR)$(DATADIR)/$$(dirname "$$file")"; \
		install -m 644 "$$file" "$(DESTDIR)$(DATADIR)/$$file" || exit; \
	done

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/holbuild" "$(DESTDIR)$(DATADIR)/copyrights/smlnj.txt" "$(DESTDIR)$(DATADIR)/LICENSE"
	@for file in $(RUNTIME_SOURCES); do rm -f "$(DESTDIR)$(DATADIR)/$$file"; done

test: bin/holbuild
	HOLBUILD_KEEP_TEST_LOGS="$(HOLBUILD_KEEP_TEST_LOGS)" HOLDIR="$(HOLDIR)" tests/run.sh $(TESTS)
ifeq ($(strip $(TESTS)),)
	$(MAKE) golden-key-dump-check
endif

clean:
	rm -f bin/holbuild bin/holbuild.o
	rmdir bin 2>/dev/null || true
