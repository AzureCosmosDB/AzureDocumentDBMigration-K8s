# Runtime-only image for MigrationEngineWeb.
# Expects the pre-published output at ./MigrationEngineWeb (produced by publish-release).
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS base
WORKDIR /app
EXPOSE 8080

# Install kubectl so MigrationPodManager can shell out to it
RUN apt-get update && apt-get install -y curl ca-certificates \
    && KUBECTL_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt) \
    && curl -sSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && apt-get remove -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

COPY MigrationEngineWeb/ ./
ENV ASPNETCORE_URLS=http://+:8080
ENTRYPOINT ["dotnet", "MigrationEngineWeb.dll"]
