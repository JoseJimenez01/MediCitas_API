FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY Project_Restaurant_API/Project_Restaurant_API.csproj Project_Restaurant_API/
RUN dotnet restore Project_Restaurant_API/Project_Restaurant_API.csproj
COPY Project_Restaurant_API/ Project_Restaurant_API/
RUN dotnet publish Project_Restaurant_API/Project_Restaurant_API.csproj -c Release -o /app --no-restore

FROM build AS tests
COPY Project_Restaurant_API.Tests/ Project_Restaurant_API.Tests/
RUN dotnet build Project_Restaurant_API.Tests/Project_Restaurant_API.Tests.csproj -c Release
ENTRYPOINT ["dotnet", "test", "Project_Restaurant_API.Tests/Project_Restaurant_API.Tests.csproj", "-c", "Release", "--no-build"]

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /app ./
COPY --chmod=755 scripts/api-entrypoint.sh /app/api-entrypoint.sh
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["/app/api-entrypoint.sh"]
