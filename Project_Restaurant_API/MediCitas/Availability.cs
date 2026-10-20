using System.Text.Json;
using StackExchange.Redis;

namespace Project_Restaurant_API.MediCitas;

public sealed record Slot(Guid ProfesionalId, DateTimeOffset Inicio, DateTimeOffset Fin);
public sealed record AvailabilityResult(Guid ProfesionalId, DateOnly Fecha, long Version, bool CacheHit, List<Slot> Espacios);

public sealed class Availability(IConnectionMultiplexer redis, ILogger<Availability> logger)
{
    public static bool Overlaps(DateTimeOffset start, DateTimeOffset end, DateTimeOffset otherStart, DateTimeOffset otherEnd)
        => start < otherEnd && otherStart < end;

    public async Task<AvailabilityResult> GetAsync(MedicalSession session, Guid professional, Guid service, DateOnly date, CancellationToken ct)
    {
        var data = await session.OneAsync("""
            SELECT c.zona_horaria, c.agenda_version, s.duracion_minutos FROM med.clinicas c
            JOIN med.servicios s ON s.clinica_id = c.id
            JOIN med.profesional_servicios ps ON ps.clinica_id = s.clinica_id AND ps.servicio_id = s.id
            JOIN med.profesionales p ON p.clinica_id = ps.clinica_id AND p.id = ps.profesional_id
            WHERE p.id = @professional AND s.id = @service AND p.activo AND s.activo
            """, ct, ("professional", professional), ("service", service));
        var version = (long)data["agendaVersion"]!;
        var key = $"med:availability:{session.Identity.ClinicaId}:{professional}:{service}:{date:yyyy-MM-dd}:v{version}";
        try
        {
            var cached = await redis.GetDatabase().StringGetAsync(key);
            if (cached.HasValue)
            {
                var parsed = JsonSerializer.Deserialize<List<Slot>>(cached.ToString());
                if (parsed is not null) return new(professional, date, version, true, parsed);
            }
        }
        catch (Exception ex) when (ex is RedisException or TimeoutException or JsonException)
        {
            logger.LogWarning("Consulta de cache no disponible: {Type}", ex.GetType().Name);
        }
        var zone = TimeZoneInfo.FindSystemTimeZoneById((string)data["zonaHoraria"]!);
        var duration = (int)data["duracionMinutos"]!;
        var weekday = date.DayOfWeek == DayOfWeek.Sunday ? 7 : (int)date.DayOfWeek;
        var hours = await session.QueryAsync("SELECT inicio, fin FROM med.horarios WHERE profesional_id = @professional AND dia_semana = @day ORDER BY inicio",
            ct, ("professional", professional), ("day", weekday));
        var dayStart = TimeZoneInfo.ConvertTimeToUtc(date.ToDateTime(TimeOnly.MinValue), zone);
        var dayEnd = TimeZoneInfo.ConvertTimeToUtc(date.AddDays(1).ToDateTime(TimeOnly.MinValue), zone);
        var busy = await session.QueryAsync("""
            SELECT inicio, fin FROM med.citas WHERE profesional_id = @professional AND estado = 'reservada'
                AND inicio < @end AND fin > @start
            UNION ALL SELECT inicio, fin FROM med.bloqueos WHERE profesional_id = @professional
                AND inicio < @end AND fin > @start
            """, ct, ("professional", professional), ("start", dayStart), ("end", dayEnd));
        var slots = new List<Slot>();
        foreach (var block in hours)
        {
            var start = date.ToDateTime((TimeOnly)block["inicio"]!);
            var end = date.ToDateTime((TimeOnly)block["fin"]!);
            for (var local = start; local.AddMinutes(duration) <= end; local = local.AddMinutes(duration))
            {
                if (zone.IsInvalidTime(local) || zone.IsInvalidTime(local.AddMinutes(duration))) continue;
                var utc = new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(local, zone));
                var finish = utc.AddMinutes(duration);
                if (!busy.Any(b => Overlaps(utc, finish, new DateTimeOffset((DateTime)b["inicio"]!), new DateTimeOffset((DateTime)b["fin"]!))))
                    slots.Add(new Slot(professional, utc, finish));
            }
        }
        try
        {
            await redis.GetDatabase().StringSetAsync(key, JsonSerializer.Serialize(slots), TimeSpan.FromMinutes(5));
        }
        catch (Exception ex) when (ex is RedisException or TimeoutException)
        {
            logger.LogWarning("Escritura de cache no disponible: {Type}", ex.GetType().Name);
        }
        return new(professional, date, version, false, slots);
    }
}
