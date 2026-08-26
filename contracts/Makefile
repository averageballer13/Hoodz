# =============================================================================
#  Hoodz DAO - contracts Makefile
#  UNAUDITED. Do not deploy with real value at risk without a full audit.
#
#  Everything here runs from contracts/. Copy ../.env.example to ../.env first;
#  the deploy targets source it so PRIVATE_KEY et al. reach forge.
# =============================================================================

.DEFAULT_GOAL := help
.PHONY: help install build compile test test-gas fuzz fmt fmt-check snapshot \
        coverage sizes clean deps dry-testnet dry-mainnet deploy-testnet \
        deploy-mainnet verify-testnet verify-mainnet manifest chain-id

# --- configuration -----------------------------------------------------------

ENV_FILE       := ../.env
MAINNET_RPC    := robinhood
TESTNET_RPC    := robinhood_testnet
MAINNET_CHAIN  := 4663
TESTNET_CHAIN  := 46630
MAINNET_SCOUT  := https://robinhoodchain.blockscout.com/api
TESTNET_SCOUT  := https://testnet.robinhoodchain.blockscout.com/api
DEPLOY_SCRIPT  := script/DeployRobinhood.s.sol:DeployRobinhood
VERIFY_SCRIPT  := script/Verify.s.sol:Verify

# `--slow` sends one transaction at a time, which the Blockscout indexer prefers.
FORGE_FLAGS    := --broadcast --slow -vvvv

# Load .env when it exists so `forge script` sees PRIVATE_KEY, PONS_* and friends.
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
endif

# --- help --------------------------------------------------------------------

help: ## Show this help
	@echo "Hoodz DAO - contracts"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""

# --- setup -------------------------------------------------------------------

install: deps ## Install node deps (OpenZeppelin, solc) and forge-std
	npm install --no-audit --no-fund

deps: ## Vendor forge-std into lib/ (OpenZeppelin stays in node_modules via remappings)
	@test -d lib/forge-std || forge install foundry-rs/forge-std --no-commit

# --- build & test ------------------------------------------------------------

build: ## forge build
	forge build

compile: ## Standalone solc type-check of src/ - no Foundry required
	node compile.js

test: ## Run the whole test suite
	forge test -vvv

test-gas: ## Run the tests and print a gas report
	forge test --gas-report

fuzz: ## Run the fuzz/invariant profile with a high run count
	FOUNDRY_PROFILE=ci forge test -vvv

fmt: ## Format every .sol file in place
	forge fmt

fmt-check: ## Fail if anything is unformatted (use in CI)
	forge fmt --check

snapshot: ## Write .gas-snapshot
	forge snapshot

coverage: ## Line coverage over src/
	forge coverage --report summary

sizes: ## EIP-170 runtime size report
	forge build --sizes

clean: ## Remove build output
	forge clean
	rm -rf out cache broadcast artifacts cache-hardhat

# --- deploy ------------------------------------------------------------------
# Dry runs first: identical to the real thing minus --broadcast.

dry-testnet: ## Simulate the full deployment against Robinhood testnet (46630)
	forge script $(DEPLOY_SCRIPT) --rpc-url $(TESTNET_RPC) -vvvv

dry-mainnet: ## Simulate the full deployment against Robinhood mainnet (4663)
	forge script $(DEPLOY_SCRIPT) --rpc-url $(MAINNET_RPC) -vvvv

deploy-testnet: ## Deploy + verify on Robinhood testnet (46630)
	forge script $(DEPLOY_SCRIPT) \
		--rpc-url $(TESTNET_RPC) \
		$(FORGE_FLAGS) \
		--verify --verifier blockscout --verifier-url $(TESTNET_SCOUT)
	@$(MAKE) --no-print-directory manifest

deploy-mainnet: ## Deploy + verify on Robinhood mainnet (4663)
	@echo ">>> MAINNET DEPLOY. This code is UNAUDITED. Ctrl-C now if that is not intentional."
	@sleep 5
	forge script $(DEPLOY_SCRIPT) \
		--rpc-url $(MAINNET_RPC) \
		$(FORGE_FLAGS) \
		--verify --verifier blockscout --verifier-url $(MAINNET_SCOUT)
	@$(MAKE) --no-print-directory manifest

manifest: ## Copy the PONS launch manifest into docs/
	@if [ -f deployments/pons-launch.json ]; then \
		mkdir -p ../docs && cp deployments/pons-launch.json ../docs/pons-launch.json; \
		echo "docs/pons-launch.json updated"; \
	else \
		echo "no deployments/pons-launch.json - run a deploy target first"; \
	fi

# --- verification ------------------------------------------------------------
# Prints one ready-to-paste `forge verify-contract` command per deployed contract.

verify-testnet: ## Print Blockscout verification commands for the testnet deployment
	forge script $(VERIFY_SCRIPT) --rpc-url $(TESTNET_RPC) -vv

verify-mainnet: ## Print Blockscout verification commands for the mainnet deployment
	forge script $(VERIFY_SCRIPT) --rpc-url $(MAINNET_RPC) -vv

# --- sanity ------------------------------------------------------------------

chain-id: ## Confirm both RPCs answer with the expected chain ids
	@echo -n "mainnet (expect $(MAINNET_CHAIN)): " && cast chain-id --rpc-url $(MAINNET_RPC)
	@echo -n "testnet (expect $(TESTNET_CHAIN)): " && cast chain-id --rpc-url $(TESTNET_RPC)
