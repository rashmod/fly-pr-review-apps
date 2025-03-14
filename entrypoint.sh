#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

GITHUB_REPOSITORY_NAME=${GITHUB_REPOSITORY#$GITHUB_REPOSITORY_OWNER/}
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$GITHUB_REPOSITORY_OWNER-$GITHUB_REPOSITORY_NAME}"
# Change underscores to hyphens.
app="${app//_/-}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="${INPUT_CONFIG:-fly.toml}"
build_args=""
build_secrets=""

postgres_vm_cpus=1
postgres_volume_size=1
postgres_initial_cluster_size=1

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true

  # Delete the database only if a new one was created
  if [ "$INPUT_POSTGRES" = "new" ]; then
    db_name="${app}-db"
    echo "Deleting Postgres cluster $db_name"
    flyctl apps destroy "$db_name" -y|| true
  else
    echo "Skipping Postgres deletion since an existing database was used."
  fi

  exit 0
fi

if [ -n "$INPUT_BUILD_ARGS" ]; then
  for ARG in $(echo "$INPUT_BUILD_ARGS" | tr " " "\n"); do
    build_args="$build_args --build-arg ${ARG}"
  done
fi

if [ -n "$INPUT_BUILD_SECRETS" ]; then
  for ARG in $(echo "$INPUT_BUILD_SECRETS" | tr " " "\n"); do
    build_secrets="$build_secrets --build-secret ${ARG}"
  done
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  # Backup the original config file since 'flyctl launch' messes up the [build.args] section
  cp "$config" "$config.bak"
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --region "$region" --org "$org" $INPUT_LAUNCH_OPTIONS ${build_args} ${build_secrets}
  # Restore the original config file
  cp "$config.bak" "$config"
fi
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
fi

# Attach postgres cluster to the app if specified.
if [ -n "$INPUT_POSTGRES" ]; then
    if [ "$INPUT_POSTGRES" = "new" ]; then
        # Create a new Postgres cluster and attach it to the app.
        db_name="${app}-db"

        # Create the new Postgres cluster if it doesn't already exist.
        if flyctl apps list --org "$org" | grep -q "$db_name"; then
            echo "Postgres cluster $db_name already exists."
        else
            echo "Creating new Postgres cluster: $db_name"
            flyctl postgres create --name "$db_name" --region "$region" --org "$org" --vm-cpus $postgres_vm_cpus --initial-cluster-size $postgres_initial_cluster_size --volume-size $postgres_volume_size
        fi

        # Attach the new Postgres cluster to the app.
        echo "Attaching to new Postgres cluster: $db_name"
        flyctl postgres attach "$db_name" --app "$app" || true
    else
        # If the Postgres cluster already exists, attach it to the app.
        echo "Attaching to existing Postgres cluster: $INPUT_POSTGRES"
        flyctl postgres attach "$INPUT_POSTGRES" --app "$app" || true
    fi
else
    echo "No Postgres cluster specified."
fi

# Trigger the deploy of the new version.
echo "Contents of config $config file: " && cat "$config"
if [ -n "$INPUT_VM" ]; then
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-size "$INPUT_VMSIZE" ${build_args} ${build_secrets} $INPUT_DEPLOY_OPTIONS
else
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-cpu-kind "$INPUT_CPUKIND" --vm-cpus $INPUT_CPU --vm-memory "$INPUT_MEMORY" ${build_args} ${build_secrets} $INPUT_DEPLOY_OPTIONS
fi

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT
