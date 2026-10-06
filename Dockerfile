FROM dart:stable
WORKDIR /app
# Copy only source and tests. Secrets are provided at runtime by the host.
COPY server.dart server_test.dart cloud_test.dart ./
RUN dart run server_test.dart
RUN dart run cloud_test.dart
RUN dart compile exe server.dart -o /app/matchly-server
EXPOSE 10000
USER 65534:65534
CMD ["/app/matchly-server"]
