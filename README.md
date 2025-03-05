# Self hosted github runner

Inspired by https://testdriven.io/blog/github-actions-docker/

## Build

```
docker compose build --pull
```

## Runner token

* Go to [Runner settings -> New Runner](https://github.com/saez0pub/testing-self-hosted-cache/settings/actions/runners/new)
* Linux
* x64
* Add `RUNNER_TOKEN=<the token>` in .docker_env

## Run
* adjust http://cache-server env variables to your ip for container actions

```
docker compose pull
docker compose up -d --build
```