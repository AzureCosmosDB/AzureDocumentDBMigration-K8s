# Runtime-only image for MigrationEngine.
# Expects the pre-published output at ./MigrationEngine (produced by publish-release).
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS base
WORKDIR /app

COPY MigrationEngine/ ./
ENTRYPOINT ["dotnet", "MigrationEngine.dll"]
