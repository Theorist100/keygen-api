# syntax=docker/dockerfile:1

# Убираем жесткую привязку RAILS_ENV, чтобы он задавался при запуске
ARG BUNDLE_WITHOUT_ARG="development:test"

# Base image
FROM ruby:3.3.8-alpine AS base

ENV BUNDLE_WITHOUT="${BUNDLE_WITHOUT_ARG}" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_DEPLOYMENT="1"

# Build stage
FROM base AS build
WORKDIR /app
COPY ./Gemfile /app/Gemfile
COPY ./Gemfile.lock /app/Gemfile.lock

# ИЗМЕНЕНО: Добавляем dos2unix в список установки
RUN apk add --no-cache \
  git \
  bash \
  build-base \
  libxml2-dev \
  libxslt-dev \
  yaml-dev \
  tzdata \
  openssl \
  postgresql-dev \
  libc6-compat \
  libstdc++ \
  dos2unix && \
  bundle config --global without "${BUNDLE_WITHOUT}"  && \
  bundle config --global path "${BUNDLE_PATH}" && \
  bundle config --global deployment "${BUNDLE_DEPLOYMENT}" && \
  bundle config --global retry 5 && \
  bundle install && \
  find /usr/local/bundle/ \( -name "*.c" -o -name "*.o" -o -name "*.a" -o -name "*.h" -o -name "Makefile" -o -name "*.md" \) -delete && \
  chmod -R a+r "${BUNDLE_PATH}"

# Final stage
FROM base
LABEL maintainer="keygen.sh <oss@keygen.sh>"

# ИЗМЕНЕНО: Добавляем dos2unix и сюда
RUN apk add --no-cache bash postgresql-client tzdata libc6-compat libstdc++ dos2unix && \
  adduser -h /app -g keygen -u 1000 -s /bin/bash -D keygen

COPY --from=build --chown=keygen:keygen /usr/local/bundle/ /usr/local/bundle
WORKDIR /app
COPY . /app

# ИЗМЕНЕНО: Принудительно конвертируем концы строк всех скриптов в формат Unix
RUN dos2unix /app/scripts/*.sh && \
    dos2unix /app/bin/* && \
    chmod +x /app/scripts/entrypoint.sh && \
    chown -R keygen:keygen /app

ENV KEYGEN_EDITION="CE" KEYGEN_MODE="singleplayer" RAILS_LOG_TO_STDOUT="1" PORT="3000" BIND="0.0.0.0"
USER keygen
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["web"]