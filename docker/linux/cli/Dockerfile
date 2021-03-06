# Dockerfile for Azure/batch-shipyard (cli)

FROM alpine:3.7
MAINTAINER Fred Park <https://github.com/Azure/batch-shipyard>

ARG GIT_BRANCH
ARG GIT_COMMIT

RUN apk update \
    && apk add --update --no-cache \
        musl build-base python3 python3-dev libressl-dev libffi-dev \
        ca-certificates libressl openssh-client rsync git bash \
    && git clone -b $GIT_BRANCH --single-branch https://github.com/Azure/batch-shipyard.git /opt/batch-shipyard \
    && cd /opt/batch-shipyard \
    && git checkout $GIT_COMMIT \
    && rm -rf .git \
    && rm -f .git* .travis.yml *.yml install* \
    && pip3 install --no-cache-dir -r requirements.txt \
    && pip3 install --no-cache-dir --no-deps -r req_nodeps.txt \
    && python3 -m compileall -f /opt/batch-shipyard/shipyard.py /opt/batch-shipyard/convoy \
    && apk del --purge build-base python3-dev libressl-dev libffi-dev git \
    && rm /var/cache/apk/*

ENTRYPOINT ["/opt/batch-shipyard/shipyard.py"]
