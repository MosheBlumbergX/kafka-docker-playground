#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -f $HOME/.aws/config ]
then
     log "ERROR: $HOME/.aws/config is not set"
     exit 1
fi
if [ ! -f $HOME/.aws/credentials ]
then
     log "ERROR: $HOME/.aws/credentials is not set"
     exit 1
fi

${DIR}/../../environment/plaintext/start.sh "${PWD}/docker-compose.plaintext.yml"

# cleanup
set +e
aws_docker_cli logs delete-log-group --log-group my-log-group
set -e

log "Create a log group in AWS CloudWatch Logs."
aws_docker_cli logs create-log-group --log-group my-log-group

log "Create a log stream in AWS CloudWatch Logs."
aws_docker_cli logs create-log-stream --log-group my-log-group --log-stream my-log-stream

log "Insert Records into your log stream."
# If this is the first time inserting logs into a new log stream, then no sequence token is needed.
# However, after the first put, there will be a sequence token returned that will be needed as a parameter in the next put.
aws_docker_cli logs put-log-events --log-group my-log-group --log-stream my-log-stream --log-events timestamp=`date +%s000`,message="This is a log #0"

log "Injecting more messages"
for i in $(seq 1 10)
do
     token=$(aws_docker_cli logs describe-log-streams --log-group my-log-group | jq_docker_cli -r .logStreams[0].uploadSequenceToken)
     aws_docker_cli logs put-log-events --log-group my-log-group --log-stream my-log-stream --log-events timestamp=`date +%s000`,message="This is a log #${i}" --sequence-token ${token}
done

log "Creating AWS CloudWatch Logs Source connector"
docker exec connect \
     curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class": "io.confluent.connect.aws.cloudwatch.AwsCloudWatchSourceConnector",
                    "tasks.max": "1",
                    "aws.cloudwatch.logs.url": "https://logs.us-east-1.amazonaws.com",
                    "aws.cloudwatch.log.group": "my-log-group",
                    "aws.cloudwatch.log.streams": "my-log-stream",
                    "confluent.license": "",
                    "confluent.topic.bootstrap.servers": "broker:9092",
                    "confluent.topic.replication.factor": "1"
          }' \
     http://localhost:8083/connectors/aws-cloudwatch-logs-source/config | jq_docker_cli .

sleep 5

log "Verify we have received the data in my-log-group.my-log-stream topic"
docker exec broker kafka-console-consumer -bootstrap-server broker:9092 --topic my-log-group.my-log-stream --from-beginning --max-messages 10
