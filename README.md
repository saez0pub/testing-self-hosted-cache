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
* Adjust `RUNNER_TOKEN=<the token>` in .docker_env

## Run
* adjust http://yourip env variables to your ip for container actions in [.docker_env](.docker_env)

```
docker compose pull
docker compose up -d --build
```