COMMONS_MK_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
COMMONS_BIN := $(COMMONS_MK_DIR)/../bin/commons
COMMONS_PROJECT_ROOT := $(CURDIR)
COMMONS_RESERVED := lint audit test build validate plan shell db keys remote secrets

export ENV
export CONFIRM

COMMONS_MODULES := $(shell python3 -I $(COMMONS_MK_DIR)/../lib/modules.py $(COMMONS_PROJECT_ROOT) list)

define COMMONS_MODULE_RULES
.PHONY: $(1).lint $(1).audit $(1).test $(1).build $(1).validate $(1).plan $(1).shell $(1).keys $(1).db $(1).remote $(1).secrets
$(1).lint:
	@$(COMMONS_BIN) hook $(1) lint $(ARGS)
$(1).audit:
	@$(COMMONS_BIN) hook $(1) audit $(ARGS)
$(1).test:
	@$(COMMONS_BIN) hook $(1) test $(ARGS)
$(1).build:
	@$(COMMONS_BIN) hook $(1) build $(ARGS)
$(1).validate:
	@$(COMMONS_BIN) hook $(1) validate $(ARGS)
$(1).plan:
	@$(COMMONS_BIN) hook $(1) plan $(ARGS)
$(1).shell:
	@$(COMMONS_BIN) shell $(1)
$(1).keys:
	@$(COMMONS_BIN) keys $(1)
$(1).db:
	@$(COMMONS_BIN) db $(1)
$(1).remote:
	@$(COMMONS_BIN) remote $(1) $(ARGS)
$(1).secrets:
	@$(COMMONS_BIN) secrets $(1)
endef

define COMMONS_RUN_RULE
.PHONY: $(1).$(2)
$(1).$(2):
	@$(COMMONS_BIN) run $(1) $(2) $(ARGS)
endef


.PHONY: conform
conform:
	@$(COMMONS_BIN) conform

$(foreach module,$(COMMONS_MODULES),$(eval $(call COMMONS_MODULE_RULES,$(module))))

$(foreach module,$(COMMONS_MODULES),\
  $(foreach script,$(notdir $(wildcard $(COMMONS_PROJECT_ROOT)/$(shell python3 -I $(COMMONS_MK_DIR)/../lib/modules.py $(COMMONS_PROJECT_ROOT) dir $(module) code)/run/*)),\
    $(if $(filter $(script),$(COMMONS_RESERVED)),,$(eval $(call COMMONS_RUN_RULE,$(module),$(script))))))
