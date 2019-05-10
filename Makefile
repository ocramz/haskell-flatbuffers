# Based on https://github.com/roman/Haskell-capataz/blob/master/Makefile

################################################################################

STACK:=stack $(STACK_ARGS)

################################################################################

ghcid:  ## Launch ghcid
	ghcid \
		--command "stack ghci" \
			--restart package.yaml
.PHONY: ghcid

ghcid-test:  ## Launch ghcid and automatically run all tests
	ghcid \
		--command "stack ghci --test" \
		--test main \
		--restart package.yaml
.PHONY: ghcid-test

ghcid-unit:  ## Launch ghcid and automatically run unit tests
	ghcid \
		--command "stack ghci --test" \
		--test ":main --skip=/FlatBuffers.Integration" \
		--restart package.yaml
.PHONY: ghcid-unit

ghcid-integration:  ## Launch ghcid and automatically run integration tests
	ghcid \
		--command "stack ghci --test" \
		--test ":main --match=/FlatBuffers.Integration" \
		--restart package.yaml
.PHONY: ghcid-integration

flatb: ## Generate java flatbuffers
	flatc -o ./test-api/src/main/java/ --java \
		./test/Examples/schema.fbs \
		./test/Examples/vector_of_unions.fbs
.PHONY: flatb

test-api: ## Generate java flatbuffers and launch test-api
	make flatb
	cd ./test-api/ && \
		sbt "~reStart"
.PHONY: test-api

test-api-detached: ## Generate java flatbuffers and launch test-api in detached mode
	make flatb
	cd ./test-api/ && \
		sbt -Djline.terminal=jline.UnsupportedTerminal run &
.PHONY: test-api-detached

hlint: ## Runs hlint on the project
	hlint .
.PHONY: hlint

docs:  ## Builds haddock documentation and watch files for changes
	$(STACK) haddock --no-haddock-deps --file-watch
.PHONY: docs

################################################################################

help:	## Display this message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
.PHONY: help
.DEFAULT_GOAL := help
