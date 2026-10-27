# Narrow UI-test environment only. Its image ID is recorded separately from PE tests.
FROM keytrail-wine:1.2
USER root
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends libxtst6 && rm -rf /var/lib/apt/lists/*
USER 10001:10001
