#!/usr/bin/env bash

JQ="jq --raw-output --exit-status"

set -e
set -u
set -o pipefail

ENV=$1
VERSION=$2

DOCKER_IMAGE='recifegourmet-api'
SERVICE_PORT=8000
CONTAINER_PORT=80

TAG_SUFFIX=''
ECS_CLUSTER='recifegourmet-production'
ECS_TASK_FAMILY="$DOCKER_IMAGE-production"
ECS_SERVICE="$DOCKER_IMAGE-production"
LB_NAME='recifegourmet-production-api'
DESIRE_COUNT=2

# Memory resources
API_MEMORY=768
SIDEKIQ_MEMORY=384
REDIS_MEMORY=100

if [ "$ENV" ==  "staging" ]; then
  TAG_SUFFIX='-beta'
  ECS_CLUSTER='recifegourmet-staging'
  ECS_TASK_FAMILY="$DOCKER_IMAGE-staging"
  ECS_SERVICE="$DOCKER_IMAGE-staging"
  DESIRE_COUNT=1
  LB_NAME='recifegourmet-staging-api'

  # Override environment variables for staging
  SECRET_KEY_BASE=$STAGING_SECRET_KEY_BASE

  # Database
  RG_DATABASE_HOST=$STAGING_RG_DATABASE_HOST
  RG_DATABASE_NAME=$STAGING_RG_DATABASE_NAME
  RG_DATABASE_USERNAME=$STAGING_RG_DATABASE_USERNAME
  RG_DATABASE_PASSWORD=$STAGING_RG_DATABASE_PASSWORD

  # AWS
  RG_AWS_ACCESS_KEY_ID=$STAGING_RG_AWS_ACCESS_KEY_ID
  RG_AWS_SECRET_ACCESS_KEY=$STAGING_RG_AWS_SECRET_ACCESS_KEY
  RG_AWS_REGION=$STAGING_RG_AWS_REGION
  RG_AWS_UPLOADS_BUCKET=$STAGING_RG_AWS_UPLOADS_BUCKET
  RG_AWS_UPLOADS_BASE_URL=$STAGING_RG_AWS_UPLOADS_BASE_URL
fi

if [ "$ENV" ==  "development" ]; then
  TAG_SUFFIX='-alpha'
  ECS_CLUSTER='recifegourmet-dev'
  ECS_TASK_FAMILY="$DOCKER_IMAGE-dev"
  ECS_SERVICE="$DOCKER_IMAGE-dev"
  DESIRE_COUNT=1
  LB_NAME='recifegourmet-dev-api'

  # Override environment variables for staging
  SECRET_KEY_BASE=$DEV_SECRET_KEY_BASE

  # Database
  RG_DATABASE_HOST=$DEV_RG_DATABASE_HOST
  RG_DATABASE_NAME=$DEV_RG_DATABASE_NAME
  RG_DATABASE_USERNAME=$DEV_RG_DATABASE_USERNAME
  RG_DATABASE_PASSWORD=$DEV_RG_DATABASE_PASSWORD

  # AWS
  RG_AWS_ACCESS_KEY_ID=$DEV_RG_AWS_ACCESS_KEY_ID
  RG_AWS_SECRET_ACCESS_KEY=$DEV_RG_AWS_SECRET_ACCESS_KEY
  RG_AWS_REGION=$DEV_RG_AWS_REGION
  RG_AWS_UPLOADS_BUCKET=$DEV_RG_AWS_UPLOADS_BUCKET
  RG_AWS_UPLOADS_BASE_URL=$DEV_RG_AWS_UPLOADS_BASE_URL
fi


deploy_image() {
  `aws ecr get-login`
  docker tag $DOCKER_IMAGE:$VERSION $DOCKER_REGISTRY/$DOCKER_IMAGE:$VERSION$TAG_SUFFIX
  docker push $DOCKER_REGISTRY/$DOCKER_IMAGE:$VERSION$TAG_SUFFIX
}

create_task_definition() {
    task_definition='{
        "containerDefinitions": [
            {
                "name": "'$DOCKER_IMAGE'",
                "image": "'$DOCKER_REGISTRY'/'$DOCKER_IMAGE':'$VERSION$TAG_SUFFIX'",
                "memory": '$API_MEMORY',
                "cpu": 512,
                "essential": true,
                "portMappings": [
                    {
                        "hostPort": '$SERVICE_PORT',
                        "containerPort": '$CONTAINER_PORT',
                        "protocol": "tcp"
                    }
                ],
                "command": [ "bundle", "exec", "puma", "-C", "config/puma.rb" ],
                "environment": [
                  { "name": "SECRET_KEY_BASE",                 "value": "'$SECRET_KEY_BASE'" },
                  { "name": "RG_DATABASE_HOST",                "value": "'$RG_DATABASE_HOST'" },
                  { "name": "RG_DATABASE_NAME",                "value": "'$RG_DATABASE_NAME'" },
                  { "name": "RG_DATABASE_USERNAME",            "value": "'$RG_DATABASE_USERNAME'" },
                  { "name": "RG_DATABASE_PASSWORD",            "value": "'$RG_DATABASE_PASSWORD'" },
                  { "name": "RG_AWS_ACCESS_KEY_ID",            "value": "'$RG_AWS_ACCESS_KEY_ID'" },
                  { "name": "RG_AWS_SECRET_ACCESS_KEY",        "value": "'$RG_AWS_SECRET_ACCESS_KEY'" },
                  { "name": "RG_AWS_REGION",                   "value": "'$RG_AWS_REGION'" },
                  { "name": "RG_AWS_UPLOADS_BUCKET",           "value": "'$RG_AWS_UPLOADS_BUCKET'" },
                  { "name": "RG_AWS_UPLOADS_BASE_URL",         "value": "'$RG_AWS_UPLOADS_BASE_URL'" }
              ]
            }
            ],
        "family": "'$ECS_TASK_FAMILY'"
    }'

    echo $task_definition > /tmp/task_definition.json

  if revision=$(aws ecs register-task-definition --cli-input-json file:///tmp/task_definition.json --family $ECS_TASK_FAMILY | \
                  $JQ '.taskDefinition.taskDefinitionArn'); then
    echo "Create new revision of task definition: $revision"
  else
    echo "Failed to register task definition"
    return 1
  fi
}

create_service() {
  if [ "$ENV" ==  "production" ]; then
    service='{
        "serviceName": "'$ECS_SERVICE'",
        "taskDefinition": "'$ECS_TASK_FAMILY'",
        "desiredCount": '$DESIRE_COUNT',
        "loadBalancers": [
          {
            "containerName": "'$DOCKER_IMAGE'",
            "containerPort": '$CONTAINER_PORT',
            "loadBalancerName": "'$LB_NAME'"
          }
        ],
        "role": "ecsServiceRole"
    }'

    echo $service > /tmp/service.json
  else
    service='{
        "serviceName": "'$ECS_SERVICE'",
        "taskDefinition": "'$ECS_TASK_FAMILY'",
        "desiredCount": '$DESIRE_COUNT'
    }'

    echo $service > /tmp/service.json
  fi

  if [[ $(aws ecs create-service --cluster $ECS_CLUSTER --service-name $ECS_SERVICE --cli-input-json file:///tmp/service.json | \
            $JQ '.service.serviceName') == "$ECS_SERVICE" ]]; then
    echo "Service created: $ECS_SERVICE"
  else
    echo "Error to create service: $ECS_SERVICE"
    return 1
  fi
}

stop_service() {
  echo "Stop the service: $ECS_SERVICE"

  if [[ $(aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --desired-count 0 | \
            $JQ ".service.serviceName") == "$ECS_SERVICE" ]]; then

    for attempt in {1..30}; do
      if stale=$(aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE | \
                  $JQ ".services[0].deployments | .[] | select(.taskDefinition != \"$revision\") | .taskDefinition"); then
        echo "Waiting the service stops: $stale"
        sleep 5
      else
        echo "Service stopped: $ECS_SERVICE"
        return 0
      fi
    done

    echo "Stopping the service $ECS_SERVICE took too long."
    return 1
  else
    echo "Error to stop service: $ECS_SERVICE"
    return 1
  fi
}

start_service() {
  echo "Start the service: $ECS_SERVICE"

  if [[ $(aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --desired-count $DESIRE_COUNT | \
            $JQ ".service.serviceName") == "$ECS_SERVICE" ]]; then


    for attempt in {1..60}; do
      if [[ $(aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE | \
                  $JQ ".services[0].runningCount") == "$DESIRE_COUNT" ]]; then
        echo "Service started: $ECS_SERVICE"
        return 0
      else
        echo "Waiting the service starts..."
        sleep 5
      fi
    done

    echo "Starting the service $ECS_SERVICE took too long."
    return 1
  else
    echo "Error to start service: $ECS_SERVICE"
    return 1
  fi
}

restart_service() {
  if [[ $(aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE | \
            $JQ '.services[0].runningCount') == "0" ]]; then
    start_service
  else
    stop_service
    start_service
  fi
}

update_service() {
  if [[ $(aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --task-definition $revision | \
            $JQ '.service.taskDefinition') == "$revision" ]]; then
    echo "Service updated: $revision"
  else
    echo "Error to update service: $ECS_SERVICE"
    return 1
  fi
}

create_or_update_service() {
  if [[ $(aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE | \
            $JQ '.failures | .[] | .reason') == "MISSING" ]]; then
    create_service
  else
    update_service
    restart_service
  fi
}

deploy_server() {
  # curl -X POST -H 'Content-Type: application/json' --data "{ 'text': 'Starting $DOCKER_IMAGE deployment in $ENV.' }" $SLACK_URL
  echo "creating server"
  create_task_definition
  create_or_update_service
}

# Deployment

deploy_image
deploy_server
