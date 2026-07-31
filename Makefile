.PHONY: validate build release clean

validate:
	python3 scripts/validate-release.py .

build: validate
	./build.sh

release: validate
	./scripts/package-release.sh

clean:
	rm -rf wrt1900acsv2-uboot-full dist
