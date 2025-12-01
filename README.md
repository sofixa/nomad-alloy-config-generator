# nomad-alloy-config-generator
Python script to generate a Grafana Alloy configuration file with scrape targets for Nomad log files

For an example job spec for an Alloy system job, cf [alloy-collector.nmd.hcl](./alloy-collector.nmd.hcl). 

Prerequisites are a readonly ACL policy assigned to the Alloy job to get access to the Task API, and a volume per node for Alloy (optional, but recommended). 
