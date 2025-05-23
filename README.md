# benchmark-control-plane
Scripts to benchmark kube control plane for various combinations. Some of the combinations are:

## Objectives
1. Benchmark the control-plane consisting of minkapi,kube-scheduler with simple 5k, 10pk pods
1. Benchmark the control-plane consisting of kine,kube-scheduler with simple 5k, 10pk pods
1. Benchmark the control-plane consisting of kine,kube-scheduler with objects from a large HANA clusters
1. Benchmark the control-plane consisting of minkapi,kube-scheduler with objects from a large Hana cluster

## Usage

1. Execute `setup.sh`
2. Choose one of the above objectives and execute one of the benchmark scripts starting with `benchmark-*.sh`

## Reports

The scripts generate reports that are generated into the `docs/` folder which is served as Github Pages website

