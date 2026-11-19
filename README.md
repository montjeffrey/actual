# Test scripts for actualbudget/actual#9338

This branch is not part of Actual. It holds the scripts and the two entrypoint
patches from my review of [#9338](https://github.com/actualbudget/actual/pull/9338),
and a workflow that runs them on a GitHub-hosted runner: once on the runner's
own Docker storage driver and once with the engine switched to `vfs`.

The workflow reads actualbudget/actual at the commit under review, builds the
images, runs the scripts and uploads their logs. It pushes nothing and uses no
secrets. The branch is temporary.
