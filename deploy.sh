#!/bin/bash

# Help
HELP="Usage: ./deploy.sh [COMMAND]\n
\tCommands:\n
\t\tstart \t Start a blockchain\n
\t\tstop \t Stop a blockchain\n
\t\trelayer \t Start a relayer\n
\t\trelayer-stop \t Stop a relayer"

# Make sure a command is given
if [ $# -lt 1 ]; then
    echo "Missing commands"
    echo -e $HELP
    exit 0
fi

CMD=${1}

DERIVATION_PATH="m/44'/60'/0'/0/0"

SUDO="sudo"

if [ $CMD = "start" ]; then
    # Usage
    USAGE="Usage: ./deploy.sh start <chain type> <chain name> <number of nodes> <chain id integer> [OPTIONS]\n
    \t\"chain type\" can be "evmos" or "gaia"\n
    \tOptions:\n
    \t\t--build \t Build the baton docker image\n
    \t\t--help  \t\t Print help\n
    \t\t--network \t Create docker network"

    NUM_ARGS=5

    # Check for help
    # Perform option actions
    counter=0
    while [ $counter -le $# ]
    do  
        if [ "${!counter}" = "--help" ]; then
            # Echo the help
            echo -e $USAGE
            exit 1
        fi
        ((counter++))
    done

    # Check for correct arguments
    if [ $# -lt $NUM_ARGS ]; then
        echo "Invalid arguments"
        echo -e $USAGE
        exit 1
    fi

    ########### Define important chain specific variables########
    CHAIN_ID_PREFIX="evmos_9000"
    account_prefix="'evmos'"
    address_type="address_type = { derivation = 'ethermint', proto_type = { pk_type = '/ethermint.crypto.v1.ethsecp256k1.PubKey' } }"
    gas_price="{ price = 1767812500, denom = 'aevmos' }"
    max_gas="3000000"
    trusting_period="'14days'"
    BINARY="evmosd"
    STAKING_TOKEN="aevmos"
    CHAIN_NAME="evmos"
    if [ ${2} = "gaia" ]; then
        CHAIN_ID_PREFIX="cosmoshub"
        account_prefix="'cosmos'"
        address_type=""
        gas_price="{ price = 0.01, denom = 'uatom' }"
        max_gas="10000000"
        trusting_period="'1days'"
        BINARY="gaiad"
        STAKING_TOKEN="uatom"
        CHAIN_NAME="gaia"
    fi

    MONIKER=${3}
    CHAINID_NUM="${5}"
    CHAINID="${CHAIN_ID_PREFIX}-${CHAINID_NUM}"
    HOMEDIR_PREFIX=$(pwd)"/build/.${MONIKER}"
    VALIDATOR_PREFIX="dev${MONIKER}"
    MEMORY="./.memory-${MONIKER}"
    NUM_NODES=${4}
    ###########################################################

    # Create hermes directory
    if [ ! -d "./build/hermes" ]; then
        mkdir ./build/hermes
    fi

    # Template configuration for hermes
    HERMES_CHAIN_CONFIG="[[chains]]\n
        id = '${CHAINID}'\n
        grpc_addr = 'http://127.0.0.1:9190'\n
        rpc_addr = 'http://localhost:26757'\n
        event_source = { mode = 'push', url = 'ws://127.0.0.1:26657/websocket', batch_delay = '500ms' }\n
        rpc_timeout = '15s'\n
        account_prefix = ${account_prefix}\n
        key_name = 'devmoon'\n
        ${address_type}\n
        store_prefix = 'ibc'\n
        gas_price = ${gas_price}\n
        gas_multiplier = 1.1\n
        max_gas = ${max_gas}\n
        max_msg_num = 30\n
        max_tx_size = 2097152\n
        clock_drift = '5s'\n
        max_block_time = '30s'\n
        trusting_period = ${trusting_period}\n
        trust_threshold = { numerator = '2', denominator = '3' }\n"

    # Create a validator for each of the nodes
    VALIDATORS=()
    HOMEDIRS=()
    counter=0
    while [ $counter -lt $NUM_NODES ];
    do
        VALIDATORS+=("${VALIDATOR_PREFIX}${counter}")
        HOMEDIRS+=("${HOMEDIR_PREFIX}${counter}")
        ((counter++))
    done

    # Evmos command for creating a validator
    VALIDATOR_TX="./${BINARY} tx staking create-validator --amount=1000000000000000000000${STAKING_TOKEN} --chain-id $CHAINID --pubkey=\"\$(./${BINARY} tendermint show-validator --home /${2})\" --moniker=$MONIKER --commission-rate=\"0.1\" --commission-max-rate=\"0.20\" --commission-max-change-rate=\"0.01\" --min-self-delegation=\"1\" --gas=\"auto\" FROM "
    if [ ${2} = "gaia" ]; then
        VALIDATOR_TX="./${BINARY} tx staking create-validator --amount=1000000000000000000000${STAKING_TOKEN} --chain-id $CHAINID --pubkey=\"\$(./${BINARY} tendermint show-validator --home /${2})\" --moniker=$MONIKER --commission-rate=\"0.1\" --commission-max-rate=\"0.20\" --commission-max-change-rate=\"0.01\" --gas=\"auto\" FROM "
    fi

    echo "Validators: ${VALIDATORS[*]}"
    echo "Home Directories: ${HOMEDIRS[*]}"

    PEERING_PORT="26656"
    NODEADDR="tcp://localhost:26657"
    GENESIS=${HOMEDIRS[0]}/config/genesis.json
    TMP_GENESIS=${HOMEDIRS[0]}/config/tmp_genesis.json

    # Create new info for each node
    counter=$(( $NUM_NODES - 1 ))
    $SUDO rm -rf "./build/hermes/hermes-${CHAINID_NUM}"
    mkdir "./build/hermes/hermes-${CHAINID_NUM}" # Directory that will store key files for this chain (for hermes relayer)
    while [ $counter -ge 0 ]
    do
        # Remove old data
        sudo rm -rf "${HOMEDIRS[((${counter}))]}"

        ./build/${BINARY} config chain-id $CHAINID --home "${HOMEDIRS[((${counter}))]}"
        ./build/${BINARY} config node $NODEADDR --home "${HOMEDIRS[((${counter}))]}"
        ./build/${BINARY} keys add "${VALIDATORS[((${counter}))]}" --output json --keyring-backend test --home "${HOMEDIRS[((${counter}))]}" > "./build/hermes/hermes-${CHAINID_NUM}/rkey${counter}.json"

        # The argument $MONIKER is the custom username of your node, it should be human-readable.
        ./build/${BINARY} init $MONIKER --chain-id=$CHAINID --home "${HOMEDIRS[((${counter}))]}"
        ((counter--))
    done

    # Input hermes chain configuration data
    echo -e $HERMES_CHAIN_CONFIG > "./build/hermes/hermes-${CHAINID_NUM}/chain.toml"
    $SUDO sed -i "s+rpc_addr =.*+rpc_addr = \'http://${VALIDATORS[0]}:26657\'+g" "./build/hermes/hermes-${CHAINID_NUM}/chain.toml"
    $SUDO sed -i "s+grpc_addr =.*+grpc_addr = \'http://${VALIDATORS[0]}:9090\'+g" "./build/hermes/hermes-${CHAINID_NUM}/chain.toml"
    $SUDO sed -i "s+id =.*+id = \'${CHAINID}\'+g" "./build/hermes/hermes-${CHAINID_NUM}/chain.toml"
    $SUDO sed -i "s+ws://127\.0\.0\.1:26657/websocket+ws://${VALIDATORS[0]}:26657/websocket+g" "./build/hermes/hermes-${CHAINID_NUM}/chain.toml"
    $SUDO sed -i "s+key_name =.*+key_name = \'${VALIDATORS[0]}\'+g" "./build/hermes/hermes-${CHAINID_NUM}/chain.toml"

    # Choose only one of the genesis files to modify
    # Change parameter token denominations to $STAKING_TOKEN
    jq ".app_state[\"staking\"][\"params\"][\"bond_denom\"]=\"${STAKING_TOKEN}\"" "$GENESIS" >"$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
    jq ".app_state[\"crisis\"][\"constant_fee\"][\"denom\"]=\"${STAKING_TOKEN}\"" "$GENESIS" >"$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
    jq ".app_state[\"gov\"][\"deposit_params\"][\"min_deposit\"][0][\"denom\"]=\"${STAKING_TOKEN}\"" "$GENESIS" >"$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
    jq ".app_state[\"evm\"][\"params\"][\"evm_denom\"]=\"${STAKING_TOKEN}\"" "$GENESIS" >"$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
    jq ".app_state[\"inflation\"][\"params\"][\"mint_denom\"]=\"${STAKING_TOKEN}\"" "$GENESIS" >"$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

    jq '.consensus_params["block"]["max_gas"]='"\"${max_gas}\"" "$GENESIS" >"$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
    
    # Initialize genesis accounts and validators
    counter=0
    while [ $counter -lt $NUM_NODES ]
    do
        $SUDO ./build/${BINARY} add-genesis-account "${VALIDATORS[((${counter}))]}"  "${NUM_NODES}00000000000000000000000000${STAKING_TOKEN}" --keyring-backend test --home "${HOMEDIRS[((${counter}))]}"
        $SUDO ./build/${BINARY} gentx "${VALIDATORS[((${counter}))]}"   "1000000000000000000000${STAKING_TOKEN}" --chain-id $CHAINID --keyring-backend test --home "${HOMEDIRS[((${counter}))]}"

        $SUDO ./build/${BINARY} collect-gentxs --home "${HOMEDIRS[((${counter}))]}"
        $SUDO ./build/${BINARY} validate-genesis --home "${HOMEDIRS[((${counter}))]}"
        ((counter++))
    done

    # Copy the gensis file to all of the nodes other
    # Also, set min-gas-prices in all app.toml
    counter=0
    while [ $counter -lt $NUM_NODES ]
    do
        $SUDO cp "$GENESIS" "${HOMEDIRS[((${counter}))]}/config/genesis.json"
        $SUDO sed -i "s/minimum-gas-prices.*/minimum-gas-prices = \"0${CHAIN_NAME}\"/g" "${HOMEDIRS[((${counter}))]}/config/app.toml"
        ((counter++))
    done

    # Get a seed so that other nodes can establish p2p connection
    SEED=$(./build/${BINARY} tendermint show-node-id --home "${HOMEDIRS[0]}")"@192.255.${CHAINID_NUM}.2:"${PEERING_PORT}

    # Replace seed in all of the node config files
    counter=0
    while [ $counter -lt $NUM_NODES ]
    do
        $SUDO sed -i "s/seeds = .*/seeds = \"$SEED\"/g" "${HOMEDIRS[((${counter}))]}/config/config.toml"
        $SUDO sed -i "s+^laddr = .*tcp://.*\:+laddr = \"tcp://0.0.0.0\:+g" "${HOMEDIRS[((${counter}))]}/config/config.toml"
        ((counter++))
    done

    # Perform option actions
    counter=$(( $NUM_ARGS + 1 ))
    while [ $counter -le $# ]
    do  
        if [ "${!counter}" = "--build" ]; then
            # Build a new docker image
             $SUDO docker build -t sldavidson/baton:${CHAIN_NAME} .
        elif [ "${!counter}" = "--network" ]; then
            # Create bridge network
             $SUDO docker network create --subnet "192.255.0.0/16" "baton-net"
        fi
        ((counter++))
    done

    # Start the containers
    echo "" > "${MEMORY}.txt"
    counter=0
    while [ $counter -lt $NUM_NODES ]
    do  
         docker container create --name "${VALIDATORS[((${counter}))]}" --volume "${HOMEDIRS[((${counter}))]}:/${CHAIN_NAME}" --network "baton-net" --ip "192.255.${CHAINID_NUM}.$(( $counter + 2 ))" sldavidson/baton:${CHAIN_NAME} ./${BINARY} start --home /${CHAIN_NAME}
         docker container start "${VALIDATORS[((${counter}))]}" && echo "${VALIDATORS[((${counter}))]}" >> "${MEMORY}.txt"

         # Connect first container to overlay network
        if [ $counter -eq 0 ]; then
            docker network connect baton-overlay "${VALIDATORS[((${counter}))]}"
        fi
        ((counter++))
    done

    counter=0
    while [ $counter -lt $NUM_NODES ]
    do  
        # Add a script to the container that will allow this node to become a validator
         docker exec "${VALIDATORS[((${counter}))]}" /bin/bash -c "echo \"#!/bin/bash\" > add_validator.sh" 
         docker exec "${VALIDATORS[((${counter}))]}" /bin/bash -c "echo -e ${VALIDATOR_TX} >> add_validator.sh"
         docker exec "${VALIDATORS[((${counter}))]}" chmod 777 add_validator.sh
         docker exec "${VALIDATORS[((${counter}))]}" sed -i "s/NODEADDR/192.255.${CHAINID_NUM}.$(( $counter + 2 )):26657/g" add_validator.sh
         docker exec "${VALIDATORS[((${counter}))]}" sed -i 's=FROM=\\=g' add_validator.sh
         docker exec "${VALIDATORS[((${counter}))]}" sed -i 's="=\\"=g' add_validator.sh
         docker exec "${VALIDATORS[((${counter}))]}" sed -i 's=\\\\=\\=g' add_validator.sh
         docker exec "${VALIDATORS[((${counter}))]}" sed -i 's={=\\{=g' add_validator.sh
         docker exec "${VALIDATORS[((${counter}))]}" sed -i 's=}=\\}=g' add_validator.sh
         docker exec "${VALIDATORS[((${counter}))]}" /bin/bash -c "echo \"--home /${CHAIN_NAME} --node tcp://192.255.${CHAINID_NUM}.$(( $counter + 2 )):26657 --keyring-backend test --fees 500000000000000${STAKING_TOKEN} --from=\$(./${BINARY} keys show ${VALIDATORS[((${counter}))]} --home /${CHAIN_NAME} --keyring-backend test -a) -y\" >> add_validator.sh"
        ((counter++))
    done

    # Create script to transfer 50000000000000000000000000aevmos between node accounts
     docker exec "${VALIDATORS[0]}" /bin/bash -c "echo \"#!/bin/bash\" > transfer_funds.sh"
     docker exec "${VALIDATORS[0]}" /bin/bash -c "chmod 777 transfer_funds.sh"
    # This script will wait for a new block to be committed to the blockchain, and will proceed afterwards
    # This prevents sequence number clashing from transactions
    NEW_BLOCK_SCRIPT="#!/bin/bash
counter=0
while [ \$counter -lt 1 ]
do
        end_loop=0
        start_data=\$(./${BINARY} query block --home /${CHAIN_NAME} --node tcp://192.255.${CHAINID_NUM}.2:26657)
        while [ \$end_loop -eq 0 ]
        do
                sleep 1
                block_data=\$(./${BINARY} query block --home /${CHAIN_NAME} --node tcp://192.255.${CHAINID_NUM}.2:26657)
                if [ \"\$start_data\" = \"\$block_data\" ]; then
                        echo 'Waiting for another block...'
                else
                        echo 'Submitting transaction'
                        end_loop=1
                fi
        done
        ((counter++))
done"

    counter=1
    while [ $counter -lt $NUM_NODES ]
    do
        OTHER_ADDRESS=$( docker exec ${VALIDATORS[((${counter}))]} ./${BINARY} keys show ${VALIDATORS[((${counter}))]} --home /${CHAIN_NAME} --keyring-backend test -a)
         docker exec "${VALIDATORS[0]}" /bin/bash -c "echo \"./${BINARY} tx bank send \$(./${BINARY} keys show ${VALIDATORS[0]} --home /${CHAIN_NAME} --keyring-backend test -a) ${OTHER_ADDRESS} 50000000000000000000000000${STAKING_TOKEN} --from \$(./${BINARY} keys show ${VALIDATORS[0]} --home /${CHAIN_NAME} --keyring-backend test -a) --home /${CHAIN_NAME} --keyring-backend test --node tcp://192.255.${CHAINID_NUM}.2:26657 --fees 500000000000000${STAKING_TOKEN} -y\" >> transfer_funds.sh"
         docker exec "${VALIDATORS[0]}" /bin/bash -c "echo -e '${NEW_BLOCK_SCRIPT}' >> transfer_funds.sh"
        ((counter++))
    done

    echo "Transfering funds to validators..."
    sleep 3

    # Send funds to each node so that every node can become a validator
     docker exec "${VALIDATORS[0]}" ./transfer_funds.sh

    # Register validators
    echo "Registering validators..."
    sleep 3

    counter=1
    while [ $counter -lt $NUM_NODES ]
    do
         docker exec "${VALIDATORS[((${counter}))]}" ./add_validator.sh
        # sleep 3
        ((counter++))
    done    
elif [ $CMD = "stop" ]; then
    # Usage
    USAGE="Usage: ./deploy.sh stop <chain name> [OPTIONS]\n
    \tOptions:\n
    \t\t--network \t Remove network configuration (baton-net)"
    NUM_ARGS=2

    # Check for help
    # Perform option actions
    counter=0
    while [ $counter -le $# ]
    do  
        if [ "${!counter}" = "--help" ]; then
            # Echo the help
            echo -e $USAGE
            exit 1
        fi
        ((counter++))
    done

    # Check for correct arguments
    if [ $# -lt $NUM_ARGS ]; then
        echo "Invalid arguments"
        echo -e $USAGE
        exit 1
    fi

    if [ -f "./.memory-${2}.txt" ]; then
         docker container stop $(cat "./.memory-${2}.txt")
         docker container rm $(cat "./.memory-${2}.txt")
    fi

    # Perform option actions
    counter=$(( $NUM_ARGS + 1 ))
    while [ $counter -le $# ]
    do  
        if [ "${!counter}" = "--network" ]; then
            # Create bridge network
             docker network remove "baton-net"
        fi
        ((counter++))
    done

    if [ -f "./.memory-${2}.txt" ]; then
        rm "./.memory-${2}.txt"
    fi
elif [ $CMD = "relayer" ]; then
    # Usage
    USAGE="Usage: ./deploy.sh relayer <chain-1-id> <chain-1-port> <chain-2-id> <chain-2-port> <channel-version> <node-1-id> <node-2-id> [OPTIONS]\n
    \tOptions:\n
    \t\t--build \t Build the relayer image\n
    \t\t--swarm \t Attach container to overlay network"
    NUM_ARGS=8
    OVERLAY=0

    # Check for help
    # Perform option actions
    counter=0
    while [ $counter -le $# ]
    do  
        if [ "${!counter}" = "--help" ]; then
            # Echo the help
            echo -e $USAGE
            exit 1
        fi
        ((counter++))
    done

    # Check for correct arguments
    if [ $# -lt $NUM_ARGS ]; then
        echo "Invalid arguments"
        echo -e $USAGE
        exit 1
    fi

    # Set variables for channel parameters
    CA=${2} # Chain A
    PA=${3} # Port A
    CB=${4}
    PB=${5}
    CV=${6}
    NA=${7}
    NB=${8}

    # Set relayer name
    RELAYER_NAME="baton-relayer-${CA}-${CB}"

    # Hermes configuration header
    HERMES_CONFIG_HEADER="[global]
log_level = 'error'

[mode]

[mode.clients]
enabled = true
refresh = true
misbehaviour = true

[mode.connections]
enabled = true

[mode.channels]
enabled = true

[mode.packets]
enabled = true
clear_interval = 100
clear_on_start = true
tx_confirmation = true

[telemetry]
enabled = true
host = '127.0.0.1'
port = 3001\n"

    # Perform option actions
    counter=$(( $NUM_ARGS + 1 ))
    while [ $counter -le $# ]
    do  
        if [ "${!counter}" = "--build" ]; then
            # Create relayer image
            docker image pull sldavidson/baton-relayer:latest
        elif [ "${!counter}" = "--swarm" ]; then
            # Create and attach to overlay network
            OVERLAY=1
        fi
        ((counter++))
    done

    # Start the relayer container
    docker container create --name "${RELAYER_NAME}" --volume "/home/sldavidson/evmos/build/hermes:/hermes/:Z" --network "baton-net" --ip "192.255.255.$(ls -a | egrep '\.stop-' | wc -l)" sldavidson/baton-relayer:latest
    docker container start "${RELAYER_NAME}"

    # Initialize and start the connection
    docker exec "${RELAYER_NAME}" /bin/bash -c "echo -e \"${HERMES_CONFIG_HEADER}\" > config.toml"
    docker exec "${RELAYER_NAME}" /bin/bash -c "cat hermes/hermes-${CA}/chain.toml >> config.toml"
    docker exec "${RELAYER_NAME}" /bin/bash -c "sed -i 's=dev\(.*\)0:=dev\1${NA}:=g' config.toml"
    docker exec "${RELAYER_NAME}" /bin/bash -c "sed -i 's=key_name\(.*\)dev\(.*\)0=key_name\1dev\2${NA}=g' config.toml"
    docker exec "${RELAYER_NAME}" /bin/bash -c "cat hermes/hermes-${CB}/chain.toml >> config2.toml"
    docker exec "${RELAYER_NAME}" /bin/bash -c "sed -i 's=dev\(.*\)0:=dev\1${NB}:=g' config2.toml"
    docker exec "${RELAYER_NAME}" /bin/bash -c "sed -i 's=key_name\(.*\)dev\(.*\)0=key_name\1dev\2${NB}=g' config2.toml"
    docker exec "${RELAYER_NAME}" /bin/bash -c "cat config2.toml >> config.toml"
    docker exec "${RELAYER_NAME}" /bin/bash -c "hermes --config config.toml keys add --hd-path \"${DERIVATION_PATH}\" --chain evmos_9000-${CA} --key-file \"hermes/hermes-${CA}/rkey${NA}.json\""
    docker exec "${RELAYER_NAME}" /bin/bash -c "hermes --config config.toml keys add --hd-path \"${DERIVATION_PATH}\" --chain evmos_9000-${CB} --key-file \"hermes/hermes-${CB}/rkey${NB}.json\""

    if [ $OVERLAY -eq 1 ]; then
        docker network connect baton-overlay "${RELAYER_NAME}"
    fi

    # Save stop command in file
    echo " docker container stop ${RELAYER_NAME} &&  docker container rm ${RELAYER_NAME}" > ".stop-${CA}-${CB}.sh"
    chmod 755 ".stop-${CA}-${CB}.sh"

    # hermes --config config.toml create channel --a-chain evmos_9000-5 --b-chain evmos_9000-6 --a-port chat --b-port chat --channel-version chat-1 --new-client-connection
elif [ $CMD = "relayer-stop" ]; then
    # Usage
    USAGE="Usage: ./deploy.sh relayer-stop <chain-1-id> <chain-2-id>"
    NUM_ARGS=3

    # Check for correct arguments
    if [ $# -lt $NUM_ARGS ]; then
        echo "Invalid arguments"
        echo -e $USAGE
        exit 1
    fi

    # Stop the relayer container
    if [ -f ".stop-${2}-${3}.sh" ]; then
        "./.stop-${2}-${3}.sh"
        rm ".stop-${2}-${3}.sh"
    elif [ -f ".stop-${2}-${3}.sh" ]; then
        "./.stop-${3}-${2}.sh"
        rm ".stop-${3}-${2}.sh"
    else
        echo "Relayer not found"
    fi
elif [ $CMD = "create-overlay" ]; then
    # Usage
    USAGE="Usage: ./deploy.sh create-overlay"
    NUM_ARGS=1

    # Check for correct arguments
    if [ $# -lt $NUM_ARGS ]; then
        echo "Invalid arguments"
        echo -e $USAGE
        exit 1
    fi

    # Create an overlay network
    docker network create -d overlay --attachable baton-overlay
elif [ $CMD = "stats" ]; then
    NUM_ARGS=2

    # Check for correct arguments
    if [ $# -lt $NUM_ARGS ]; then
        echo "Invalid arguments"
        echo -e $USAGE
        exit 1
    fi

    counter=2
    while [ $counter -le $# ]
    do  
        # Get stats on network information
        CONTAINER_ID=$(docker ps --no-trunc --filter name="${!counter}\$" --format "{{.ID}}")
        curl -v --unix-socket /var/run/docker.sock "http://localhost/containers/${CONTAINER_ID}/stats" | jq '{"name": .["name"]} + {"time": .["read"]} + .["networks"] + {"cpu": .["cpu_stats"] | .["cpu_usage"] | .["total_usage"]}'
        ((counter++))
    done
else
    echo "Invalid command: ${1}"
    echo -e $HELP
    exit 0
fi

# copy over config
# cp ./earth_config/app.toml "$HOMEDIR/config/app.toml"
# cp ./earth_config/config.toml "$HOMEDIR/config/config.toml"

# hermes add keys
# hermes --config config.toml keys delete --chain evmos_9000-4 --all
# hermes --config config.toml keys add --hd-path "m/44'/60'/0'/0/0" --chain evmos_9000-4 --key-file devearth-key-info

# evmosd start --json-rpc.enable --home $HOMEDIR

# curl -v --unix-socket /var/run/docker.sock http://localhost/containers/779982e8c4c6395d15908c726a3435642a89c0faf8e4899ef67671f99cd8f800/stats | jq '{"time": .["read"]} + .["networks"]'