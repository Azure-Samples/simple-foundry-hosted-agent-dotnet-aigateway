FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
WORKDIR /app
EXPOSE 8088
ENV ASPNETCORE_URLS=http://+:8088

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY FoundryHostedAgent.AIGateway.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish FoundryHostedAgent.AIGateway.csproj \
    --configuration Release \
    --no-restore \
    --output /app/publish

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "FoundryHostedAgent.AIGateway.dll"]
