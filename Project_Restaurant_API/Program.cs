using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using Npgsql;
using Project_Restaurant_API.Auth;
using Project_Restaurant_API.Data;
using Project_Restaurant_API.MediCitas;
using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;
var legacyConnection = new NpgsqlConnectionStringBuilder(MedicalDatabase.Connection(config)) { Options = "-c role=med_legacy" };
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
{
    options.SwaggerDoc("v1", new OpenApiInfo { Title = "MediCitas API", Version = "v1" });
    options.AddSecurityDefinition("Bearer", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.Http, Scheme = "bearer", BearerFormat = "JWT"
    });
    options.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        [new OpenApiSecurityScheme { Reference = new OpenApiReference { Type = ReferenceType.SecurityScheme, Id = "Bearer" } }] = []
    });
});
builder.Services.AddDbContext<RestaurantContext>(options => options.UseNpgsql(legacyConnection.ConnectionString));
builder.Services.AddSingleton<MedicalDatabase>();
builder.Services.AddSingleton<IConnectionMultiplexer>(_ => ConnectionMultiplexer.Connect(new ConfigurationOptions
{
    EndPoints = { config["REDIS_CONNECTION"] ?? "redis:6379" },
    AbortOnConnectFail = false,
    ConnectTimeout = 3000,
    SyncTimeout = 3000,
    AsyncTimeout = 3000
}));
builder.Services.AddSingleton<Availability>();
builder.Services.AddHttpClient<KeycloakDirectory>(client => client.Timeout = TimeSpan.FromSeconds(10));

var authority = config["KEYCLOAK_AUTHORITY"] ?? "http://auth:8080/realms/restaurant";
var audience = config["KEYCLOAK_AUDIENCE"] ?? config["KEYCLOAK_CLIENT_ID"] ?? "restaurant-api";
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer(options =>
{
    options.Authority = authority;
    options.Audience = audience;
    options.MapInboundClaims = false;
    options.RequireHttpsMetadata = !authority.StartsWith("http://", StringComparison.OrdinalIgnoreCase);
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer = true,
        ValidIssuer = config["KEYCLOAK_VALID_ISSUER"] ?? authority,
        ValidateAudience = true,
        ValidAudience = audience,
        ValidateLifetime = true,
        RequireSignedTokens = true,
        ValidateIssuerSigningKey = true,
        ClockSkew = TimeSpan.FromSeconds(30)
    };
});
builder.Services.AddAuthorization(options => options.AddPolicy("Escritura",
    p => p.RequireRole(config["KEYCLOAK_REQUIRED_ROLE"] ?? "api-writer")));
builder.Services.AddSingleton<IClaimsTransformation, KeycloakClaimsTransformation>();

var app = builder.Build();
if (args.Contains("--initialize-only") || config.GetValue("INITIALIZE_DATABASE", true))
    await MedicalDatabase.InitializeAsync(config, app.Logger);
if (args.Contains("--initialize-only")) return;

app.Use(async (context, next) =>
{
    try { await next(context); }
    catch (DomainException ex)
    {
        context.Response.StatusCode = ex.Status;
        await context.Response.WriteAsJsonAsync(new { message = ex.Message });
    }
    catch (PostgresException ex)
    {
        var (status, message) = ex.SqlState switch
        {
            "23P01" => (409, "El espacio ya esta ocupado o se solapa con otro intervalo."),
            "23505" => (409, "El recurso ya existe."),
            "23503" or "P0002" => (400, "Una referencia no existe o no pertenece a su clinica."),
            "23514" or "22007" or "22008" or "22023" => (400, "La solicitud incumple las reglas del dominio."),
            "P0001" => (409, "La transicion de estado no esta permitida."),
            "40P01" or "40001" or "55P03" => (409, "Conflicto concurrente; vuelva a intentar la operacion."),
            "42501" => (403, "Acceso no permitido."),
            _ => (500, "No se pudo completar la operacion.")
        };
        if (status == 500) app.Logger.LogError("Error PostgreSQL {Code}", ex.SqlState);
        context.Response.StatusCode = status;
        await context.Response.WriteAsJsonAsync(new { message });
    }
    catch (NpgsqlException)
    {
        context.Response.StatusCode = 503;
        await context.Response.WriteAsJsonAsync(new { message = "Base de datos temporalmente no disponible." });
    }
    catch (ArgumentException)
    {
        context.Response.StatusCode = 400;
        await context.Response.WriteAsJsonAsync(new { message = "Parametro invalido." });
    }
});

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}
app.UseAuthentication();
app.UseAuthorization();
app.MapGet("/health", () => Results.Ok(new { status = "healthy" })).AllowAnonymous();
app.MapGet("/ready", async Task<IResult> (MedicalDatabase database, CancellationToken ct) =>
{
    try
    {
        await using var connection = new NpgsqlConnection(database.ConnectionString);
        await connection.OpenAsync(ct);
        await new NpgsqlCommand("SELECT 1", connection).ExecuteScalarAsync(ct);
        return Results.Ok(new { status = "ready" });
    }
    catch (Exception ex) when (ex is NpgsqlException or TimeoutException)
    {
        return Results.Json(new { status = "unavailable" }, statusCode: 503);
    }
}).AllowAnonymous();
app.MapControllers();
app.Run();

public partial class Program;
