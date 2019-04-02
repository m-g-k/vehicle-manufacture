#!/bin/bash
BASEDIR=$(dirname "$0")

if [ $BASEDIR = '.' ]
then
    BASEDIR=$(pwd)
elif [ $BASEDIR:1:2 = './' ]
then
    BASEDIR=$(pwd)${BASEDIR:1}
elif [ $BASEDIR:1:1 = '/' ]
then
    BASEDIR=$(pwd)${BASEDIR}
else
    BASEDIR=$(pwd)/${BASEDIR}
fi

DOCKER_COMPOSE_DIR=$BASEDIR/network/docker-compose
CRYPTO_CONFIG=$BASEDIR/network/crypto-material/crypto-config

echo "################"
echo "# GENERATE CRYPTO"
echo "################"
docker-compose -f $DOCKER_COMPOSE_DIR/docker-compose-cli.yaml up -d

docker exec cli cryptogen generate --config=/etc/hyperledger/config/crypto-config.yaml --output /etc/hyperledger/config/crypto-config
docker exec cli configtxgen -profile ThreeOrgsOrdererGenesis -outputBlock /etc/hyperledger/config/genesis.block
docker exec cli configtxgen -profile ThreeOrgsChannel -outputCreateChannelTx /etc/hyperledger/config/channel.tx -channelID vehiclemanufacture
docker exec cli cp /etc/hyperledger/fabric/core.yaml /etc/hyperledger/config
docker exec cli sh /etc/hyperledger/config/rename_sk.sh

docker-compose -f $DOCKER_COMPOSE_DIR/docker-compose-cli.yaml down --volumes

echo "################"
echo "# SETUP NETWORK"
echo "################"
docker-compose -f $DOCKER_COMPOSE_DIR/docker-compose.yaml -p node up -d

echo "################"
echo "# CHANNEL INIT"
echo "################"
docker exec arium_cli peer channel create -o orderer.example.com:7050 -c vehiclemanufacture -f /etc/hyperledger/configtx/channel.tx --outputBlock /etc/hyperledger/configtx/vehiclemanufacture.block
docker exec arium_cli peer channel join -b /etc/hyperledger/configtx/vehiclemanufacture.block --tls true --cafile /etc/hyperledger/config/crypto/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem
docker exec vda_cli peer channel join -b /etc/hyperledger/configtx/vehiclemanufacture.block --tls true --cafile /etc/hyperledger/config/crypto/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem
docker exec princeinsurance_cli peer channel join -b /etc/hyperledger/configtx/vehiclemanufacture.block --tls true --cafile /etc/hyperledger/config/crypto/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem

echo "################"
echo "# CHAINCODE INSTALL"
echo "################"
docker exec arium_cli bash -c "apk add nodejs nodejs-npm python make g++"
docker exec arium_cli bash -c 'cd /opt/gopath/src/github.com/awjh-ibm/vehicle-manufacture-contract; npm install; npm run build'
docker exec arium_cli peer chaincode install -l node -n vehicle-manufacture-chaincode -v 0 -p /opt/gopath/src/github.com/awjh-ibm/vehicle-manufacture-contract
docker exec vda_cli peer chaincode install -l node -n vehicle-manufacture-chaincode -v 0 -p /opt/gopath/src/github.com/awjh-ibm/vehicle-manufacture-contract
docker exec princeinsurance_cli  peer chaincode install -l node -n vehicle-manufacture-chaincode -v 0 -p /opt/gopath/src/github.com/awjh-ibm/vehicle-manufacture-contract

echo "################"
echo "# CHAINCODE INSTANTIATE"
echo "################"
docker exec arium_cli peer chaincode instantiate -o orderer.example.com:7050 -l node -C vehiclemanufacture -n vehicle-manufacture-chaincode -v 0 -c '{"Args":[]}' -P 'AND ("AriumMSP.member", "VDAMSP.member", "PrinceInsuranceMSP.member")'

echo "################"
echo "# BUILD CLI_TOOLS"
echo "################"
cd $BASEDIR/cli_tools
npm install
npm run build
cd $BASEDIR

echo "################"
echo "# SETUP WALLET"
echo "################"
LOCAL_FABRIC=$BASEDIR/vehiclemanufacture_fabric
ARIUM_CONNECTION=$LOCAL_FABRIC/arium_connection.json
VDA_CONNECTION=$LOCAL_FABRIC/vda_connection.json
PRINCE_CONNECTION=$LOCAL_FABRIC/prince_connection.json

mkdir -p $LOCAL_FABRIC/wallet
sed -e 's/{{LOC_ORG_ID}}/Arium/g' $BASEDIR/network/connection.tmpl > $ARIUM_CONNECTION
sed -e 's/{{LOC_ORG_ID}}/VDA/g' $BASEDIR/network/connection.tmpl > $VDA_CONNECTION
sed -e 's/{{LOC_ORG_ID}}/PrinceInsurance/g' $BASEDIR/network/connection.tmpl > $PRINCE_CONNECTION

echo "################"
echo "# ENROLLING ADMINS"
echo "################"
ARIUM_ADMIN_CERT=$BASEDIR/tmp/arium_cert.pem
ARIUM_ADMIN_KEY=$BASEDIR/tmp/arium_key.pem

VDA_ADMIN_CERT=$BASEDIR/tmp/vda_cert.pem
VDA_ADMIN_KEY=$BASEDIR/tmp/vda_key.pem

PRINCE_ADMIN_CERT=$BASEDIR/tmp/prince_cert.pem
PRINCE_ADMIN_KEY=$BASEDIR/tmp/prince_key.pem

mkdir $BASEDIR/tmp

FABRIC_CA_CLIENT_HOME=/root/fabric-ca/clients/admin

docker exec ca0.example.com bash -c "FABRIC_CA_CLIENT_HOME=$FABRIC_CA_CLIENT_HOME fabric-ca-client enroll -u http://admin:adminpw@ca0.example.com:7054"
docker exec ca0.example.com bash -c "cd $FABRIC_CA_CLIENT_HOME/msp/keystore; find ./ -name '*_sk' -exec mv {} key.pem \;"
docker cp ca0.example.com:$FABRIC_CA_CLIENT_HOME/msp/signcerts/cert.pem $BASEDIR/tmp
docker cp ca0.example.com:$FABRIC_CA_CLIENT_HOME/msp/keystore/key.pem $BASEDIR/tmp

mv $BASEDIR/tmp/cert.pem $ARIUM_ADMIN_CERT
mv $BASEDIR/tmp/key.pem $ARIUM_ADMIN_KEY

docker exec ca1.example.com bash -c "FABRIC_CA_CLIENT_HOME=$FABRIC_CA_CLIENT_HOME fabric-ca-client enroll -u http://admin:adminpw@ca1.example.com:7054"
docker exec ca1.example.com bash -c "cd $FABRIC_CA_CLIENT_HOME/msp/keystore; find ./ -name '*_sk' -exec mv {} key.pem \;"
docker cp ca1.example.com:$FABRIC_CA_CLIENT_HOME/msp/signcerts/cert.pem $BASEDIR/tmp
docker cp ca1.example.com:$FABRIC_CA_CLIENT_HOME/msp/keystore/key.pem $BASEDIR/tmp

mv $BASEDIR/tmp/cert.pem $VDA_ADMIN_CERT
mv $BASEDIR/tmp/key.pem $VDA_ADMIN_KEY

docker exec ca2.example.com bash -c "FABRIC_CA_CLIENT_HOME=$FABRIC_CA_CLIENT_HOME fabric-ca-client enroll -u http://admin:adminpw@ca2.example.com:7054"
docker exec ca2.example.com bash -c "cd $FABRIC_CA_CLIENT_HOME/msp/keystore; find ./ -name '*_sk' -exec mv {} key.pem \;"
docker cp ca2.example.com:$FABRIC_CA_CLIENT_HOME/msp/signcerts/cert.pem $BASEDIR/tmp
docker cp ca2.example.com:$FABRIC_CA_CLIENT_HOME/msp/keystore/key.pem $BASEDIR/tmp

mv $BASEDIR/tmp/cert.pem $PRINCE_ADMIN_CERT
mv $BASEDIR/tmp/key.pem $PRINCE_ADMIN_KEY

echo "################"
echo "# ENROLLING VEHICLE MANUFACTURE USERS"
echo "################"

ARIUM_USERS=$BASEDIR/users/arium.json
VDA_USERS=$BASEDIR/users/vda.json
PRINCE_USERS=$BASEDIR/users/prince-insurance.json

node $BASEDIR/cli_tools/dist/index.js import -w $LOCAL_FABRIC/wallet -m AriumMSP -n Admin@arium.com -c $ARIUM_ADMIN_CERT -k $ARIUM_ADMIN_KEY
node $BASEDIR/cli_tools/dist/index.js import -w $LOCAL_FABRIC/wallet -m VDAMSP -n Admin@vda.com -c $VDA_ADMIN_CERT -k $VDA_ADMIN_KEY
node $BASEDIR/cli_tools/dist/index.js import -w $LOCAL_FABRIC/wallet -m PrinceInsuranceMSP -n Admin@prince-insurance.com -c $PRINCE_ADMIN_CERT -k $PRINCE_ADMIN_KEY

node $BASEDIR/cli_tools/dist/index.js enroll -w $LOCAL_FABRIC/wallet -c $ARIUM_CONNECTION -u $ARIUM_USERS -a Admin@arium.com -o Arium
node $BASEDIR/cli_tools/dist/index.js enroll -w $LOCAL_FABRIC/wallet -c $VDA_CONNECTION -u $VDA_USERS -a Admin@vda.com -o VDA
node $BASEDIR/cli_tools/dist/index.js enroll -w $LOCAL_FABRIC/wallet -c $PRINCE_CONNECTION -u $PRINCE_USERS -a Admin@prince-insurance.com -o PrinceInsurance

# echo "################"
# echo "# STARTUP REST SERVERS"
# echo "################"

# REST_DIR=$BASEDIR/../apps/rest_server

# cd $REST_DIR
# npm install
# npm run build
# cd $BASEDIR

# BOD_REST_PORT=3000
# BOD_NAME='bank of dinero'
# EB_REST_PORT=3001
# EB_NAME='eastwood banking'

# # echo "node $REST_DIR/dist/cli.js --wallet $LOCAL_FABRIC/wallet/BankOfDinero --connection-profile $ARIUM_CONNCETION --port $BOD_REST_PORT > $BASEDIR/tmp/bod_server.log 2>&1 &"
# node $REST_DIR/dist/cli.js --wallet $LOCAL_FABRIC/wallet/BankOfDinero --connection-profile $ARIUM_CONNCETION --port $BOD_REST_PORT --bank-name "$BOD_NAME" > $BASEDIR/tmp/bod_server.log 2>&1 &

# # echo "node $REST_DIR/dist/cli.js --wallet $LOCAL_FABRIC/wallet/EastwoodBanking --connection-profile $VDA_CONNECTION --port $EB_REST_PORT > $BASEDIR/tmp/eb_server.log 2>&1 &"
# node $REST_DIR/dist/cli.js --wallet $LOCAL_FABRIC/wallet/EastwoodBanking --connection-profile $VDA_CONNECTION --port $EB_REST_PORT --bank-name "$EB_NAME" > $BASEDIR/tmp/eb_server.log 2>&1 &

# printf 'WAITING FOR BANK OF DINERO REST SERVER'
# until $(curl --output /dev/null --silent --head --fail http://localhost:$BOD_REST_PORT); do
#     printf '.'
#     sleep 2
# done

# echo ""
# printf 'WAITING FOR EASTWOOD BANKING REST SERVER'
# until $(curl --output /dev/null --silent --head --fail http://localhost:$EB_REST_PORT); do
#     printf '.'
#     sleep 2
# done

# echo ""
# echo "################"
# echo "# REGISTER EVERYONE IN CHAINCODE"
# echo "################"
# PARTICIPANTS_CONTRACT="org.locnet.participants"

# curl -X POST -H "Content-Type: application/json" -d '{"bankName": "Bank of Dinero"}' -u system:systempw http://localhost:$BOD_REST_PORT/$PARTICIPANTS_CONTRACT/registerBank

# for row in $(jq -r ".[] | .name" $BOD_USERS); do
#     if [ $row != "system" ]; then
#         echo "REGISTERING $row"
#         curl -X POST -H "Content-Type: application/json" -d '{}' -u $row:${row}pw http://localhost:$BOD_REST_PORT/$PARTICIPANTS_CONTRACT/registerParticipant
#     fi
# done

# curl -X POST -H "Content-Type: application/json" -d '{"bankName": "Eastwood Banking"}' -u system:systempw http://localhost:$EB_REST_PORT/$PARTICIPANTS_CONTRACT/registerBank

# for row in $(jq -r ".[] | .name" $EB_USERS); do
#     if [ $row != "system" ]; then
#         echo "REGISTERING $row"
#         curl -X POST -H "Content-Type: application/json" -d '{}' -u $row:${row}pw http://localhost:$EB_REST_PORT/$PARTICIPANTS_CONTRACT/registerParticipant
#     fi
# done