.PHONY: lint test check

lint:
	shellcheck forge-backup.sh install.sh

test:
	bats test/forge-backup.bats

check: lint test
