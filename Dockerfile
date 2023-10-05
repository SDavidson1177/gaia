FROM golang:1.19.1

RUN apt-get update -y
RUN apt-get install git -y
RUN apt-get install ca-certificates jq -y
RUN apt-get install iproute2 -y
RUN apt-get install iputils-ping -y
RUN apt-get install tcpdump -y
RUN apt-get install nano -y

COPY ./build/gaiad .

EXPOSE 26656 26657 1317 9090 8545 8546

CMD ["tail", "-f", "/dev/null"]
