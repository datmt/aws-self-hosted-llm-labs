LAB ?= 01-ec2
TF = terraform -chdir=labs/$(LAB)

up:
	$(TF) init -input=false
	$(TF) apply -auto-approve
	@[ ! -x labs/$(LAB)/post-up.sh ] || labs/$(LAB)/post-up.sh

test:
	tests/run.sh $(LAB)

down:
	$(TF) destroy -auto-approve

# anything still tagged lab=* after a destroy
leftovers:
	aws resourcegroupstaggingapi get-resources --tag-filters Key=lab --region us-east-1 \
	  --query 'ResourceTagMappingList[].ResourceARN' --output text

# apply -> smoke x3 -> capture -> destroy (always) -> leftovers; results in runs/<lab>/<ts>/
e2e:
	tests/e2e.sh $(LAB)
