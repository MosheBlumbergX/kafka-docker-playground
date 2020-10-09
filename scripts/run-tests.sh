#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../scripts/utils.sh

# go to root folder
cd ${DIR}/..

nb_test_failed=0
nb_test_skipped=0
failed_tests=""
skipped_tests=""

test_list="$1"
if [ "$1" = "ALL" ]
then
    test_list=$(grep "env: TEST_LIST" ${DIR}/../.travis.yml | cut -d '"' -f 2 | tr '\n' ' ')
fi

tag="$2"
if [ "$tag" != "" ]
then
    export TAG=$tag
fi

for dir in $test_list
do
    if [ ! -d $dir ]
    then
        logwarn "####################################################"
        logwarn "skipping dir $dir, not a directory"
        logwarn "####################################################"
        continue
    fi

    cd $dir > /dev/null

    for script in *.sh
    do
        if [[ "$script" = "stop.sh" ]]
        then
            continue
        fi

        # check for ignored scripts in scripts/tests-ignored.txt
        grep "$script" ${DIR}/tests-ignored.txt > /dev/null
        if [ $? = 0 ]
        then
            logwarn "####################################################"
            logwarn "skipping $script in dir $dir"
            logwarn "####################################################"
            continue
        fi

        # check for scripts containing "repro"
        if [[ "$script" == *"repro"* ]]; then
            logwarn "####################################################"
            logwarn "skipping reproduction model $script in dir $dir"
            logwarn "####################################################"
            continue
        fi

        log "####################################################"
        log "Executing $script in dir $dir"
        log "####################################################"
        SECONDS=0
        retry bash $script
        ret=$?
        ELAPSED="took: $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
        let ELAPSED_TOTAL+=$SECONDS
        CUMULATED="cumulated time: $((($ELAPSED_TOTAL / 60) % 60))min $(($ELAPSED_TOTAL % 60))sec"
        if [ $ret -eq 0 ]
        then
            log "####################################################"
            log "RESULT: SUCCESS for $script in dir $dir ($ELAPSED - $CUMULATED)"
            log "####################################################"

            # Travis: do not run tests that have been successfully executed (same CP and connector version) less than 7 days ago #132
            THE_CONNECTOR_TAG=""
            docker_compose_file=$(grep "environment" "$script" | grep DIR | grep start.sh | cut -d "/" -f 7 | cut -d '"' -f 1 | head -n1)
            if [ "${docker_compose_file}" != "" ] && [ -f "${docker_compose_file}" ]
            then
                connector_path=$(grep "CONNECT_PLUGIN_PATH" "${docker_compose_file}" | cut -d "/" -f 5)
                # remove any extra comma at the end (when there are multiple connectors used, example S3 source)
                connector_path=$(echo "$connector_path" | cut -d "," -f 1)
                owner=$(echo "$connector_path" | cut -d "-" -f 1)
                name=$(echo "$connector_path" | cut -d "-" -f 2-)

                THE_CONNECTOR_TAG=$(docker run vdesabou/kafka-docker-playground-connect:${TAG} cat /usr/share/confluent-hub-components/$connector_path/manifest.json | jq -r '.version')
            fi
            file="/tmp/$TAG-$THE_CONNECTOR_TAG-$script"
            touch $file
            date +%s > $file
            if [ -f "$file" ]
            then
                aws s3 cp "$file" "s3://kafka-docker-playground/travis/"
                log "INFO: <$file> was uploaded to S3 bucket"
            else
                logerror "ERROR: $file could not be created"
                exit 1
            fi
        elif [ $ret -eq 123 ] # skipped
        then
            logwarn "####################################################"
            logwarn "RESULT: SKIPPED for $script in dir $dir ($ELAPSED - $CUMULATED)"
            logwarn "####################################################"
            skipped_tests=$skipped_tests"$dir[$script]\n"
            let "nb_test_skipped++"
        else
            logerror "####################################################"
            logerror "RESULT: FAILURE for $script in dir $dir ($ELAPSED - $CUMULATED)"
            logerror "####################################################"
            failed_tests=$failed_tests"$dir[$script]\n"
            let "nb_test_failed++"
        fi
        bash stop.sh
    done
    cd - > /dev/null
done


if [ $nb_test_failed -eq 0 ]
then
    log "####################################################"
    log "RESULT: SUCCESS"
    log "####################################################"
else
    logerror "####################################################"
    logerror "RESULT: FAILED $nb_test_failed tests failed:\n$failed_tests"
    logerror "####################################################"
    exit $nb_test_failed
fi

if [ $nb_test_skipped -ne 0 ]
then
    log "####################################################"
    log "RESULT: SKIPPED $nb_test_skipped tests skipped:\n$skipped_tests"
    log "####################################################"
fi
exit 0